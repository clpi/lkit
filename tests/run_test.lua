--- Test runner.
--
-- @script run_test
-- @copyright 2017 Aidan Holm

-- Add ./tests to package.path
package.path = package.path .. ';./tests/?.lua'

local util = require "tests.util"
local posix = require "posix"

--- Launched as the init script of a luakit instance
--
-- Loads test_file and runs all tests in it in order
local function do_test_file(test_file)
    local wait_timer = timer()

    -- Load test table
    local chunk, err = loadfile(test_file)
    assert(chunk, err)
    local T = chunk()
    local current_test

    -- Type checks
    assert(type(T) == "table")
    for test_name, func in pairs(T) do
        assert(type(test_name) == "string")
        assert(type(func) == "function" or type(func) == "thread")
        if type(func) == "function" then
            T[test_name] = coroutine.create(func)
        end
    end

    local test_object_signal_handler

    --- Runs a test untit it passes, fails, or waits for a signal
    -- Additional arguments: parameters to signal handler
    -- @treturn string Status of the test; one of "pass", "wait", "fail"
    local function begin_or_continue_test(test_name, func, ...)
        assert(type(test_name) == "string")
        assert(type(func) == "thread")

        -- Run test until it finishes, pauses, or fails
        local ok, ret = coroutine.resume(func, ...)
        local state = coroutine.status(func)

        if not ok then
            print("FAIL: " .. current_test)
            print("  " .. tostring(ret))
            return "fail"
        elseif state == "suspended" then
            print("WAIT: " .. current_test)

            -- Start timer
            local interval = ret.timeout * 1000
            wait_timer.interval = interval
            wait_timer:start()

            -- Add signal handlers to resume running test
            local obj, sig = ret[1], ret[2]
            local function wrapper(...)
                obj:remove_signal(sig, wrapper)
                test_object_signal_handler(test_name, func, ...)
            end
            obj:add_signal(sig, wrapper)

            -- Return to luakit
            return "wait"
        else
            print("PASS: " .. current_test)
            return "pass"
        end
    end

    --- Finds the next test to run and starts it, or quits
    local function do_next_test()
        repeat
            local test_name, func = next(T, current_test)
            if not test_name then
                -- Quit if all tests have been run
                luakit.quit()
                return
            end
            current_test = test_name

            local test_status = begin_or_continue_test(test_name, func)
        until test_status == "wait"
    end

    --- Resumes a waiting test when a signal occurs
    test_object_signal_handler = function (test_name, func, ...)
        assert(type(test_name) == "string")
        assert(type(func) == "thread")
        -- Stop the timeout timer
        wait_timer:stop()
        -- Continue the test
        print("CONT: " .. current_test)
        local test_status = begin_or_continue_test(test_name, func, ...)
        -- If the test finished, do the next one
        if test_status ~= "wait" then
            luakit.idle_add(function()
                do_next_test()
                return false
            end)
        end
    end

    wait_timer:add_signal("timeout", function ()
        print("Timed out: " .. current_test)
        do_next_test()
    end)

    do_next_test()
end

--- Launches an instance of luakit with a test file
local function spawn_test_file_luakit_instance(test_file)
    local command = "DISPLAY=:1 ./luakit -U --log=fatal -c tests/run_test.lua run " .. test_file .. " 2>&1"
    os.execute(command)
end

local arg = uris and uris or {}

if arg[1] == "run" then
    table.remove(arg, 1)
    local test_file = arg[1]
    assert(type(test_file) == "string")

    -- Skip other tests for now
    if test_file ~= "tests/test_yield.lua" then
        print("SKIP: " .. test_file)
        luakit.quit(0)
    end

    do_test_file(test_file)
else
    -- Launch Xephyr
    local pid_xephyr =  util.spawn({"Xephyr", ":1", "-ac", "-screen", "800x600"})

    -- Load and run all tests
    local test_files = util.find_files("tests/", "tests/test_[a-z_]*%.lua$")
    for _, test_file in ipairs(test_files) do
        spawn_test_file_luakit_instance(test_file)
    end

    -- Clean up
    posix.kill(pid_xephyr)
    util.cleanup()
end

-- vim: et:sw=4:ts=8:sts=4:tw=80

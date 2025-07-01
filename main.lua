function love.load()
    error("test error")
end

function love.update(dt)

end

function love.draw()
    
end

function love.keypressed(key)

end


-- To test debugging:
-- Mouse over the lines/code in the editor, or add the variables to the Watch list.
-- COMMENT OUT ALL LINES ABOVE and UNCOMMENT ALL LINES BELOW (ctrl + /). Lines marked for breakpoints are good debug test lines -- !breakpoint
-- local box = {
--     x = 100,
--     y = 100,
--     size = 100,
--     speed = 200,
--     color = {1, 0, 0} -- red
-- }

-- function love.load()
--     -- Initialize stuff
--     love.window.setTitle("Debug Test Game")
-- end

-- function love.update(dt)
--     -- Move the box to the right
--     box.x = box.x + box.speed * dt -- !breakpoint

--     -- Wrap around the screen
--     if box.x > love.graphics.getWidth() then
--         box.x = -box.size
--     end
-- end

-- function love.draw()
--     love.graphics.setColor(box.color)     -- !breakpoint
--     love.graphics.rectangle("fill", box.x, box.y, box.size, box.size)

--     -- Draw instructions
--     love.graphics.setColor(1, 1, 1)
--     love.graphics.print("Click the box to stop it and change its color", 20, 20)
-- end

-- function love.mousepressed(mx, my, button)
--     if button == 1 then -- Left mouse button -- !breakpoint
--         if mx >= box.x and mx <= box.x + box.size and
--            my >= box.y and my <= box.y + box.size then

--             -- Trigger on click
--             box.speed = 0
--             box.color = {0, 1, 0} -- green
--         end
--     end
-- end
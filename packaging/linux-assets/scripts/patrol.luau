--!strict

local minY = kadath.parameter.number("minY", {
    default = 245,
    min = -100000,
    max = 100000,
})
local maxY = kadath.parameter.number("maxY", {
    default = 330,
    min = -100000,
    max = 100000,
})
local speed = kadath.parameter.number("speed", {
    default = 80,
    min = 0,
    max = 1000,
})
local direction = 1

return {
    fixed_update = function(self: Kadath.Object, dt: number)
        local position = self:position()
        local nextY = position.y + speed * direction * dt
        if nextY >= maxY then
            nextY = maxY
            direction = -1
        elseif nextY <= minY then
            nextY = minY
            direction = 1
        end
        self:translate(0, nextY - position.y)
    end,
}

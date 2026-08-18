--!strict

local speed = kadath.parameter.number("speed", {
    default = 180,
    min = 0,
    max = 1000,
})

return {
    fixed_update = function(self: Kadath.Object, dt: number)
        local moveX, moveY = kadath.input.move_axis()
        self:translate(moveX * speed * dt, moveY * speed * dt)
    end,
}

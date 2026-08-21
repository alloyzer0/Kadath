--!strict

local speed = kadath.parameter.number("speed", {
    default = 180,
    min = 0,
    max = 1000,
})

local decorationSpeed = 6
local spawnedOrb = false
local runtimeAge = 0

return {
    fixed_update = function(self: Kadath.Object, dt: number)
        if self:kind() ~= "player" then
            return
        end
        local moveX, moveY = kadath.input.move_axis()
        self:translate(moveX * speed * dt, moveY * speed * dt)
    end,
    update = function(self: Kadath.Object, dt: number)
        if self:kind() == "player" and not spawnedOrb then
            local position = self:position()
            local orb = kadath.scene.spawn("runtime-orb", position.x + 180, position.y)
            orb:translate(8, 0)
            spawnedOrb = true
        elseif self:kind() == "sprite" and string.sub(self:id(), 1, 8) == "runtime-" then
            runtimeAge += dt
            self:translate(48 * dt, 0)
            if runtimeAge >= 1 then
                self:destroy()
            end
        elseif self:kind() == "sprite" then
            self:translate(decorationSpeed * dt, 0)
        end
    end,
    on_event = function(self: Kadath.Object, event: Kadath.Event)
        if event.name == "contact_begin" and self:kind() == "player" and event.other then
            kadath.event.post(event.other, "player_contact")
        elseif event.name == "player_contact" then
            local decoration = kadath.scene.find("decoration-1")
            if decoration and decoration:is_valid() then
                decoration:translate(1, 0)
            end
        end
    end,
}

--!strict
return {
    fixed_update = function(self: Kadath.Object, dt: number)
        local _, moveY = kadath.input.move_axis()
        self:translate(10 + dt - dt, moveY)
    end,
    on_event = function(self: Kadath.Object, event: Kadath.Event)
        local digit = 0
        if event.name == "contact_end" then
            digit = 1
        elseif event.name == "contact_begin" then
            digit = 2
        else
            return
        end
        local probe = kadath.scene.find("phase-probe")
        if not probe then
            error("missing Phase probe")
        end
        local position = probe:position()
        probe:set_position(position.x * 10 + digit, position.y)
    end,
}

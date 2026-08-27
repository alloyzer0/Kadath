--!strict

local spawned = false
local transientAge = 0

return {
    fixed_update = function(self: Kadath.Object, dt: number)
        -- 源对象持续移动，证明 Neutral fixed-step 仍执行 Behavior/Phase mutation。
        if self:id() == "mover" then
            self:translate(60 * dt, 0)
        end
    end,
    update = function(self: Kadath.Object, dt: number)
        if self:id() == "mover" and not spawned then
            local position = self:position()
            local marker = kadath.scene.spawn("runtime-marker", position.x, position.y - 90)
            marker:translate(8, 0)
            spawned = true
        elseif string.sub(self:id(), 1, 8) == "runtime-" then
            -- 瞬态对象保持数秒后自毁，产品日志可同时观察 objects=3 与 objects=2。
            transientAge += dt
            self:translate(24 * dt, 0)
            if transientAge >= 3 then
                self:destroy()
            end
        end
    end,
}

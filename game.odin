package game

import rl "vendor:raylib"
import gl "vendor:raylib/rlgl"
import m "core:math"
import rnd "core:math/rand"
import "core:thread"
import "core:fmt"

camera : rl.Camera

monitor_height : i32
monitor_width : i32

// seasons
game_time : f32 = 0
year : i32 = 1

// player variables
PLAYER_SPEED :: 4.8
player_position := rl.Vector3{0, 0, 0}
player_looking_angle : f32 = 0.0
player_saturation : f32 = 100

// objects
cropobject :: struct
{
    position : rl.Vector3,
    bbox_size : rl.Vector3,

    hp : i32,
    age : f32,
    damage_animation_time : f32,
}
cropobjects : [dynamic]cropobject
cropobjects_todestroy : [dynamic]int
object_spawn_cooldown : f32 = 0.0
highlighted_crop_index := -1


// particles
particle :: struct
{
    position : rl.Vector3,
    size : f32,
    color : rl.Color,
    texture : rl.Texture2D,
    max_lifetime, lifetime : f32,
    movement_speed : f32,
    movement_direction : rl.Vector3,
}
particles : [dynamic]particle
particles_todestroy : [dynamic]int
create_particle_explosion :: proc(origin : rl.Vector3, radius, particle_size, initial_speed, max_lifetime : f32, amount : i32, texture : rl.Texture2D, color : rl.Color)
{
    for i in 0..<amount
    {
        // construct the particle
        new_particle : particle
        new_particle.position = origin + radius * rl.Vector3Normalize({rnd.float32_range(-1, 1), rnd.float32_range(-1, 1), rnd.float32_range(-1, 1)})
        new_particle.movement_direction = new_particle.position - origin
        new_particle.size = particle_size
        new_particle.color = color
        new_particle.max_lifetime = max_lifetime
        new_particle.lifetime = 0
        new_particle.movement_speed = initial_speed
        new_particle.texture = texture

        // append to the array
        append(&particles, new_particle)
    }
}

// returns the index of the cropobject that is under cursor
return_clicked_cropobject_index :: proc() -> int
{
    ray := rl.GetMouseRay(rl.GetMousePosition(), camera)
    for &obj, i in cropobjects
    {
        bbox_height : f32 = obj.bbox_size.y
        if(obj.age < 10) do bbox_height *= obj.age * 0.1

        rayhit := rl.GetRayCollisionBox(ray, {obj.position - {obj.bbox_size.x * 0.5, 0, obj.bbox_size.z * 0.5}, obj.position + {obj.bbox_size.x * 0.5, bbox_height, obj.bbox_size.z * 0.5}})
        if(rayhit.hit) do return i
    }

    return -1
}

// attack effect
attack_frame := 5 // 5 when it is not playing
play_attack_effect :: proc()
{
    for attack_frame < 5
    {
        attack_frame += 1
        rl.WaitTime(0.04)
    } 
}

reset_game_data :: proc()
{
    game_time = 0
    year = 1
    player_position = 0
    player_saturation = 100
    shrink(&cropobjects, 0)
    shrink(&cropobjects_todestroy, 0)
    object_spawn_cooldown = 0
    highlighted_crop_index = -1
    shrink(&particles, 0)
    shrink(&particles_todestroy, 0)
    attack_frame = 5

    // start the game with 50 corns
    for i in 0..<15
    {
        append(&cropobjects, cropobject{{rnd.float32() * 44 - 22, 0, rnd.float32() * 44 - 22}, {1, 4, 1}, rnd.int31_max(3) + 3, rnd.float32_range(0, 5), 0})
    }
}

main :: proc()
{
    rl.SetConfigFlags({.FULLSCREEN_MODE, .MSAA_4X_HINT, .VSYNC_HINT})
    rl.InitWindow(1920, 1080, "ITU JAM GAME")
    rl.InitAudioDevice()
    
    monitor_height = rl.GetMonitorHeight(0)
    monitor_width = rl.GetMonitorWidth(0)

    particle_texture := rl.LoadTexture("res/p.png")
    mainmenu_art := rl.LoadTexture("res/art.png")
    
    // generate random grass positions
    grass_positions : [1024]rl.Vector3
    for &pos in grass_positions
    {
        pos = {rnd.float32_range(-36, 36), 0.1, rnd.float32_range(-36, 36)} 
    }

    // attack vfx
    vfx_attack_models : [5]rl.Model
    vfx_attack_models[0] = rl.LoadModel("res/vfx_attack0.vox")
    vfx_attack_models[1] = rl.LoadModel("res/vfx_attack1.vox")
    vfx_attack_models[2] = rl.LoadModel("res/vfx_attack2.vox")
    vfx_attack_models[3] = rl.LoadModel("res/vfx_attack3.vox")
    vfx_attack_models[4] = rl.LoadModel("res/vfx_attack4.vox")
    attacked_position : rl.Vector3

    // raven
    raven_models : [6]rl.Model
    raven_models[0] = rl.LoadModel("res/raven0.vox")
    raven_models[1] = rl.LoadModel("res/raven1.vox")
    raven_models[2] = rl.LoadModel("res/raven2.vox")
    raven_models[3] = rl.LoadModel("res/raven3.vox")
    raven_models[4] = rl.LoadModel("res/raven4.vox")
    raven_models[5] = rl.LoadModel("res/raven_dead.vox")
    for &model in raven_models
    {
        // unfortunately, we have to manually adjust the pivot of the models
        model.transform = rl.Matrix{
            1, 0, 0, -4,
            0, 1, 0, 0,
            0, 0, 1, -4,
            0, 0, 0, 1,}
    }
    raven_animation_frames : [8]i32 = {0, 1, 2, 1, 0, 3, 4, 3}
    raven_current_frame := 0
    raven_animation_time : f64 = 0.0
    raven_ANIMATION_DURATION :: 0.6 / 8

    // fence model
    fence_model := rl.LoadModel("res/fence.vox")
    fence_model.transform = rl.Matrix{
        1, 0, 0, -2,
        0, 1, 0, 0,
        0, 0, 1, -3.5,
        0, 0, 0, 1,
    }

    // objects
    object_MAX_COOLDOWN : f32 : 45.0
    object_models : [2]rl.Model
    object_models[0] = rl.LoadModel("res/corn_sprout.vox")
    object_models[1] = rl.LoadModel("res/corn.vox")
    for &model in object_models
    {
        // unfortunately, we have to manually adjust the pivot of the models
        model.transform = rl.Matrix{
            1, 0, 0, -4,
            0, 1, 0, 0,
            0, 0, 1, -4,
            0, 0, 0, 1,}
    }

    // sounds
    music := rl.LoadSound("res/music.ogg")
    last_played_step_sound := 0
    step_sounds : [6]rl.Sound
    step_sounds[0] = rl.LoadSound("res/step0.ogg")
    step_sounds[1] = rl.LoadSound("res/step1.ogg")
    step_sounds[2] = rl.LoadSound("res/step2.ogg")
    step_sounds[3] = rl.LoadSound("res/step3.ogg")
    step_sounds[4] = rl.LoadSound("res/step4.ogg")
    step_sounds[5] = rl.LoadSound("res/step5.ogg")
    attack_sound := rl.LoadSound("res/attack.ogg")
    eat_sound := rl.LoadSound("res/eat.ogg")
    death_sound := rl.LoadSound("res/death.ogg")

    camera = {{0, 10, 10}, {0, 0, 0}, {0, 1, 0}, 80, .PERSPECTIVE}
    camera_target_offset : rl.Vector3

    // MAIN MENU
    for !rl.IsKeyReleased(.SPACE) && !rl.WindowShouldClose()
    {
        rl.BeginDrawing()

        rl.DrawTextureEx(mainmenu_art, 0, 0, (f32(monitor_height) * f32(0.000926)), rl.WHITE)

        rl.DrawText("NAUGHTY CROW", (monitor_width - 1312) >> 1, 160, 160, {25, 25, 75, 255})
        rl.DrawText("Press Space To Begin", (monitor_width - 912) >> 1, monitor_height - 160, 80, rl.WHITE)

        rl.EndDrawing()
    }

    is_game_active := true
    game_over_time : f64
    reset_game_data()
    rl.PlaySound(music)

    // IN GAME
    for !rl.WindowShouldClose()
    {
        if(rl.IsKeyReleased(.R))
        {
            is_game_active = true
            reset_game_data()
            rl.PlaySound(music)
        }

        // Game Update
        if(is_game_active)
        {
            // seaons and time
            game_time += rl.GetFrameTime()
            if(game_time > 60)
            {
                game_time = 0
                year += 1

                if(year == 15) do player_saturation = 0
                else do rl.PlaySound(music)
            }

            // Player Input
            player_direction : rl.Vector3
            if(rl.IsKeyDown(.A)) do player_direction.x = -1
            else if(rl.IsKeyDown(.D)) do player_direction.x = 1
            if(rl.IsKeyDown(.W)) do player_direction.z = -1
            else if(rl.IsKeyDown(.S)) do player_direction.z = 1

            // update player position
            player_direction = rl.Vector3Normalize(player_direction)
            player_position += player_direction * PLAYER_SPEED * (0.5 + player_saturation * 0.01) * rl.GetFrameTime()
            if(m.abs(player_position.x) > 23)
            {
                if(player_position.x < 0) do player_position.x = -23
                else do player_position.x = 23
            }
            if(m.abs(player_position.z) > 23)
            {
                if(player_position.z < 0) do player_position.z = -23
                else do player_position.z = 23
            }

            // interpolate player angle according to its movement direction
            if(rl.Vector3LengthSqr(player_direction) > 0) do player_looking_angle = m.angle_lerp(player_looking_angle * rl.DEG2RAD, m.atan2_f32(-player_direction.z, player_direction.x), f32(rl.GetFrameTime() * 10.0)) * rl.RAD2DEG
            
            // player hunger
            player_saturation -= rl.GetFrameTime() * 4
            if(player_saturation < 0)
            {
                player_saturation = 0
                is_game_active = false
                rl.StopSound(music)
                rl.PlaySound(death_sound)
            }

            // raven walk animation
            if(rl.GetTime() - raven_animation_time > raven_ANIMATION_DURATION * f64(200 - player_saturation) * 0.01)
            {
                if((rl.Vector3LengthSqr(player_direction) > 0) || raven_current_frame % 4 != 0)
                {
                    // animate
                    raven_animation_time = rl.GetTime()
                    raven_current_frame += 1
        
                    if(raven_current_frame == 8) do raven_current_frame = 0

                    // play walk sound
                    if(raven_current_frame % 4 == 2)
                    {
                        sound_index_offset := 0
                        if(game_time > 45) do sound_index_offset = 3
                        rl.PlaySound(step_sounds[last_played_step_sound])

                        last_played_step_sound += 1
                        if(last_played_step_sound == 3) do last_played_step_sound = 0
                    }
                }
            }

            // Camera Update
            camera_target_offset += (player_direction * 0.5 - camera_target_offset) * rl.GetFrameTime() * 5.0
            camera.position = player_position + {0, 8, 6}
            camera.target = player_position * 0.96 + camera_target_offset

            // Raycasting
            clicked_object_index := return_clicked_cropobject_index()
            highlighted_crop_index = clicked_object_index // crop highlighting
            if(rl.IsMouseButtonPressed(.LEFT) && attack_frame == 5)
            {
                if(clicked_object_index != -1)
                {
                    // attack the object if it is near
                    if(rl.Vector3DistanceSqrt(player_position, cropobjects[clicked_object_index].position) < 16)
                    {
                        if(cropobjects[clicked_object_index].age < 10) do cropobjects[clicked_object_index].hp = 0
                        else do cropobjects[clicked_object_index].hp -= 1
                        cropobjects[clicked_object_index].damage_animation_time = 0.2

                        if(cropobjects[clicked_object_index].hp == 0)
                        {
                            inject_at(&cropobjects_todestroy, 0, clicked_object_index)

                            // restore hunger
                            player_saturation += cropobjects[clicked_object_index].age * 0.3
                            if(cropobjects[clicked_object_index].age >= 10) do player_saturation += 7
                            if(player_saturation > 100) do player_saturation = 100
                            
                            // emit particles
                            create_particle_explosion(cropobjects[clicked_object_index].position + {0, 1, 0}, 1, 0.1, 5, 2, i32(cropobjects[clicked_object_index].age * cropobjects[clicked_object_index].age), particle_texture, rl.YELLOW)

                            // play sound
                            rl.PlaySound(eat_sound)
                        } 
                        
                        // play attack effect
                        attack_frame = 0
                        attacked_position = cropobjects[clicked_object_index].position
                        thread.create_and_start(play_attack_effect)

                        // emit particles
                        create_particle_explosion(cropobjects[clicked_object_index].position + {0, 1, 0}, 1, 0.1, 5, 1, 20, particle_texture, rl.DARKGREEN)

                        // play sound
                        rl.PlaySound(attack_sound)
                    }
                }
            }

            // Remove the objects
            for obj_index in cropobjects_todestroy
            {
                unordered_remove(&cropobjects, obj_index)
            }
            shrink(&cropobjects_todestroy, 0)

            // cropobjects animation update
            for &obj in cropobjects
            {
                obj.damage_animation_time -= rl.GetFrameTime()
                if(obj.damage_animation_time < 0) do obj.damage_animation_time = 0
            }

            // crop object aging
            if(game_time < 45)
            {
                for &obj in cropobjects
                {
                    if(obj.age < 10) do obj.age += rl.GetFrameTime()
                }
            }

            // object spawn update
            if(game_time < 75) do object_spawn_cooldown -= rl.GetFrameTime() * (clamp(f32(len(cropobjects)), 0, 60) + 40) * 0.3
            if(object_spawn_cooldown < 0 && len(cropobjects) > 0)
            {
                random_object := rnd.choice(cropobjects[:])
                random_angle := rnd.float32_range(0, 360)
                if(random_object.age > 10)
                {
                    for r : f32 = 0; r < 360; r += 45
                    {
                        // Check if it collides
                        is_collided := false
                        random_selected_position : rl.Vector3
                        for o in cropobjects
                        {
                            random_selected_position = random_object.position + {m.sin_f32((r + random_angle) * rl.DEG2RAD) * 4, 0, m.cos_f32((r + random_angle) * rl.DEG2RAD) * 4}
                            if(10 > rl.Vector3DistanceSqrt(o.position, random_selected_position) || 23 < m.abs(random_selected_position.x) || 23 < m.abs(random_selected_position.z))
                            {
                                is_collided = true
                                break
                            }
                        }

                        // spawn if it does not
                        if(!is_collided)
                        {
                            object_spawn_cooldown = object_MAX_COOLDOWN
                            append(&cropobjects, cropobject{random_selected_position, {1, 4, 1}, rnd.int31_max(4) + year + 1, 0, 0})

                            r = 999 // break out of cycle
                        }
                    }
                }
            }

            // particles update
            for &p, i in particles
            {
                p.lifetime += rl.GetFrameTime()

                if (p.lifetime < p.max_lifetime)
                {
                    // update properties
                    p.position += p.movement_direction * p.movement_speed * rl.GetFrameTime()
                }
                else
                {
                    inject_at(&particles_todestroy, 0, i)
                }
            }
            for p_index in particles_todestroy
            {
                unordered_remove(&particles, p_index)
            }
            shrink(&particles_todestroy, 0)
        }

        // Draw Cycle
        rl.BeginDrawing()

        ground_color : rl.Color
        if(game_time < 43) do ground_color = {0, 180, 0, 255}
        else if (game_time < 45) do ground_color = {u8((game_time - 43) * 120), 180 + u8((game_time - 43) * 30), u8((game_time - 43) * 120), 255}
        else if (game_time < 58) do ground_color = {240, 240, 240, 255}
        else do ground_color = {u8((60 - game_time) * 120), 180 + u8((60 - game_time) * 30), u8((60 - game_time) * 120), 255}
        rl.ClearBackground(ground_color)
        
        rl.BeginMode3D(camera)
            
            // draw fences
            for i := -15; i < 15; i += 1
            {
                rl.DrawModelEx(fence_model, {f32(i) * 1.6 + 0.8, 0, 24}, {0, 1, 0}, f32((i % 2) * 180), 0.4, rl.WHITE)
                rl.DrawModelEx(fence_model, {f32(i) * 1.6 + 0.8, 0, -24}, {0, 1, 0}, f32((i % 2) * 180), 0.4, rl.WHITE)
                rl.DrawModelEx(fence_model, {24, 0, f32(i) * 1.6 + 0.8}, {0, 1, 0}, f32((i % 2) * 180) + 90, 0.4, rl.WHITE)
                rl.DrawModelEx(fence_model, {-24, 0, f32(i) * 1.6 + 0.8}, {0, 1, 0}, f32((i % 2) * 180) + 90, 0.4, rl.WHITE)
            }

            // draw the player
            if (player_saturation > 0)
            {
                // Draw the player alive
                rl.DrawModelEx(raven_models[raven_animation_frames[raven_current_frame]], player_position + {0, 0.1 * f32(2 - m.abs(raven_current_frame % 4 - 2)), 0}, {0, 1, 0}, player_looking_angle, {0.4, 0.4 + f32(3 - m.abs(attack_frame - 2)) * 0.02, 0.4}, rl.WHITE)
            }
            else
            {
                // Draw the player dead
                rl.DrawModelEx(raven_models[5], player_position, {0, 1, 0}, player_looking_angle, 0.4, rl.WHITE)
            }

            // draw attack animation
            if(attack_frame < 5)
            {
                rl.DrawModelEx(vfx_attack_models[attack_frame], player_position + {0, 1, 0}, {0, 1, 0}, m.atan2(attacked_position.x - player_position.x, attacked_position.z - player_position.z) * rl.RAD2DEG - 45, 0.4, rl.WHITE)
            }

            // draw cropobjects
            for obj, i in cropobjects
            {
                crop_size := rl.Vector3 {0.4, (0.5 - m.abs(obj.damage_animation_time - 0.1)), 0.4}
                colorMultiplier : u8 = u8(m.abs(obj.damage_animation_time - 0.1) * 2000 + 55)
                color := rl.Color {255, colorMultiplier, colorMultiplier, 255}
                model_index := 1
                if(obj.age < 10)
                {
                    crop_size = {0.2 + obj.age * 0.02, obj.age * 0.036, 0.2 + obj.age * 0.02}
                    color = rl.WHITE
                    model_index = 0
                }
                // crop highlighting
                if(highlighted_crop_index == i)
                {
                    cmultiplier := f32(m.sin_f64(rl.GetTime() * 5) + 3) * 0.25
                    color = {u8(cmultiplier * f32(color.r)), u8(cmultiplier * f32(color.g)), u8(cmultiplier * f32(color.b)), 255}
                } 

                rl.DrawModelEx(object_models[model_index], obj.position, {0, 1, 0}, 0, crop_size, color)

                /* Highlight crop

                I ADDED THIS TO ADD A OUTLINE EFFECT FOR CROPS BUT UNFORTUNATELY BACKFACE CULLING IS ENABLED BY
                DEFAULT IN RAYLIB AND RAYLIB DOESNT PROPERLY DRAW THE UI SO I COULDNT DISABLE BACKFACE CULLING
                I GUESS THAT WASNT THE PROBLEM IDK
                AAAAAAAAAAAAAHHHHHHH

                if(highlighted_crop_index == i)
                {
                    temp_mesh := object_models[model_index].meshes[0]
                    new_size := crop_size * 1
                    offset_matrix := rl.Matrix{
                        new_size.x, 0, 0, (obj.position.x - 4 * new_size.x),
                        0, new_size.y, 0, 0,
                        0, 0, -new_size.z, (obj.position.z - 4* -new_size.z),
                        0, 0, 0, 1
                    }
                    shader := rl.LoadMaterialDefault()
                    shader.maps[0].color = {0, 0, 0, 255}

                    for i in 0..<(temp_mesh.vertexCount)
                    {
                        temp_v := temp_mesh.vertices[i]
                        temp_mesh.vertices[i] = temp_mesh.vertices[i + 1]
                        temp_mesh.vertices[i + 1] = temp_v
                    }

                    rl.DrawMesh(temp_mesh, shader, offset_matrix)
                }*/
            }

            // draw particles
            for p in particles
            {
                rl.DrawBillboard(camera, p.texture, p.position, p.size, p.color)
            }

            // draw the ground
            for pos, i in grass_positions
            {
                rl.DrawCube(pos, 0.2, 0.1, 0.2, {0, 0, 0, u8(i % 32) + u8(6000 / (rl.Vector3LengthSqr(pos) + 72))})
            }

            
        rl.EndMode3D()

        // draw snowflakes
        if(game_time > 43)
        {
            for i in 0..<i32(135 - abs(game_time - 51) * 15)
            {
                rl.DrawRectangle(rnd.int31_max(monitor_width - 10), rnd.int31_max(monitor_height - 10), 10, 10, {255, 255, 255, 200})
            }
        }
        
        //rl.DrawFPS(0, 0)
        if(is_game_active)
        {
            // saturation bar
            rl.DrawRectangle((monitor_width - 760) >> 1, monitor_height - 180, 760, 100, rl.DARKGRAY)
            rl.DrawRectangle((monitor_width - 720) >> 1, monitor_height - 160, 720, 60, rl.ORANGE)
            rl.DrawRectangle((monitor_width - 720) >> 1, monitor_height - 160, i32(7.2 * player_saturation), 60, rl.YELLOW)
            
            // year texts
            if(game_time < 5) do rl.DrawText(rl.TextFormat("%i SPRING", 2023 + year), (monitor_width - 630) >> 1, 129, 96, {255, 255, 255, u8(255 - 51 * game_time)})
            else if (game_time > 43 && game_time < 48) do rl.DrawText(rl.TextFormat("%i WINTER", 2023 + year), (monitor_width - 598) >> 1, 129, 96, {0, 0, 0, u8(255 - 51 * (game_time - 43))})
        }
        else
        {
            rl.DrawText("YOU DIED", (monitor_width - 784) >> 1, 160, 160, rl.BLACK)
            rl.DrawText(rl.TextFormat("At the Age of %i", year), (monitor_width - 640) >> 1, 320, 80, rl.BLACK)
            rl.DrawText("Press R to Restart", (monitor_width - 808) >> 1, 920, 80, rl.BLACK)
        }

        rl.EndDrawing()
    }

    rl.CloseWindow()
}

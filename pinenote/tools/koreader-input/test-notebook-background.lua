-- Real BB8/RGB16 compositing, immutable paper, erasing/replay and load refusal.
local bundle, plugin = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. bundle .. "/?.lua;" .. bundle
    .. "/frontend/?.lua;" .. bundle .. "/common/?.lua;" .. package.path
package.cpath = bundle .. "/?.so;" .. package.cpath
local saved_print = print
print = function() end
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
print = saved_print
local B, S, Brush = require("nb_background"), require("nb_surface"), require("nb_brush")
local cfg = require("nb_config")
cfg.W, cfg.H = 80, 60
local files = {}
local nb = { dir = "/snapshot", fs = { read = function(path)
    if files[path] then return files[path] end
    return nil, "ENOENT"
end } }
local function check(ok, label) assert(ok, label); print("PASS: " .. label) end
local manifest, image = "/snapshot/backgrounds.conf", "/snapshot/background-0.pgm"
local bg = assert(B.open(nb, cfg))
check(bg:load(0) == nil, "ordinary notebook has blank paper")
files[manifest] = "wilkbook-backgrounds-v1 80 60\n0\n"
bg = assert(B.open(nb, cfg))
local paper, err = bg:load(0)
check(not paper and err, "declared missing paper is refused")
files[image] = "P5\n80 60\n255\nshort"
paper, err = bg:load(0)
check(not paper and err, "truncated raster is refused")
files[image] = "P5\n80 60\n255\n" .. string.char(85):rep(80 * 60)
paper = assert(bg:load(0))
paper:paintRect(0, 20, 80, 2, BB.COLOR_BLACK)
check(bg:load(1) == nil, "undeclared next page is blank")
check(not B.open(nb, {W=60,H=80}), "different panel size cannot silently shift paper")
files[manifest] = "wilkbook-backgrounds-v1 80 60\n0\n0\n"
check(not B.open(nb, cfg), "duplicate page is refused")
files[manifest] = "wilkbook-backgrounds-v1 80 60\n../x\n"
check(not B.open(nb, cfg), "manifest cannot name arbitrary paths")
local before = paper:copy()
local pen = {style=Brush.style("fine", "M", "pen", cfg),
             points={{x=10,y=20,p=2000},{x=70,y=20,p=2000}}}
local rubber = {style=Brush.style("fine", "M", "eraser", cfg),
                points={{x=40,y=20,p=500}}}
local strokes = {pen, rubber}
local page = S.new_page(80,60)
local full = S.new_page(80,60)
S.render_page(full, 0, strokes, cfg, nil, paper)
local function same(a,b)
    for y=0,59 do for x=0,79 do
        if a:getPixel(x,y):getColor8().a ~= b:getPixel(x,y):getColor8().a then return false end
    end end
    return true
end
for _, cbb in ipairs({false,true}) do
    BB:setUseCBB(cbb)
    for inv=0,1 do
        local fb = BB.new(80,60,BB.TYPE_BBRGB16)
        fb:setInverse(inv)
        S.blit_page(page, paper)
        S.blit_page(fb, paper)
        for _, e in ipairs(strokes) do
            Brush.render(e.style, e.points, 80,60, function(y,x0,x1,dens)
                local cmd = {comp=e.style.comp,pat=e.style.pat,dens=dens,spans={y,x0,x1}}
                S.ink(page,cmd,nil,paper)
                S.ink(fb,cmd,nil,paper)
            end)
        end
        check(same(page,full), "live pen/area erase matches replay; CBB="..tostring(cbb).." inverse="..inv)
        local want = BB.new(80,60,BB.TYPE_BBRGB16)
        want:setInverse(inv)
        S.blit_page(want,full)
        check(same(fb,want), "night-mode RGB16 eraser restores paper without inverted seams")
        for rot=0,3 do
            fb:setRotation(rot)
            S.blit_page(fb,full)
            fb:setRotation(0)
            check(same(fb,want), "physical ink/paper alignment survives rotation "..rot)
        end
        fb:free(); want:free()
    end
end
BB:setUseCBB(true)
check(full:getPixel(40,20):getColor8().a == 0,
      "area eraser restores a printed black rule rather than white")
S.render_page(page,0,{},cfg,nil,paper)
check(same(page,paper), "undoing all ink restores the paper")
page:fill(BB.COLOR_WHITE)
S.render_page(page,0,strokes,cfg,{x=30,y=10,w=20,h=25},paper)
local correct = true
for y=0,59 do for x=0,79 do
    local want = x>=30 and x<50 and y>=10 and y<35 and full:getPixel(x,y):getColor8().a or 255
    if page:getPixel(x,y):getColor8().a ~= want then correct=false end
end end
check(correct, "partial replay composes paper and ink only inside its region")
page:fill(BB.COLOR_WHITE)
S.ink(page,{comp="white",spans={20,0,79}}, {x=30,y=10,w=20,h=25},paper)
check(page:getPixel(20,20):getColor8().a == 0 and page:getPixel(40,20):getColor8().a == 255,
      "live eraser leaves floating controls untouched")
check(same(paper,before), "paper stays immutable through ink, erasing and replay")
for _, b in ipairs({paper,before,page,full}) do b:free() end
print("RESULT: ok")

package.path = "./?.lua;../../packages/koreader-device/plugins/notebook.koplugin/?.lua;" .. package.path
local Sample, J, Brush, C = require("sample"), require("nb_journal"), require("nb_brush"), require("nb_config")
local id = "20260926T120000Z-00c0de"
local root = "/snapshot"
local meta = '{"format":"wilkbook-notebook","v":1,"id":"' .. id
    .. '","created":0,"abs":[20966,15725,4095],"panel":[1872,1404,227]}\n'
local function record(a, tool, rot, gap)
    return J.stroke_record(a, Brush.style("fine", "M", tool or "pen", C), rot or 0, 1000,
        {{t=1000,rawx=0,rawy=0,p=100,tx=-2,ty=3},
         {t=2000,rawx=20966,rawy=15725,p=200,tx=4,ty=-5}}, gap, {0,0,1871,1403})
end
local function export(records, label, tail, region)
    local lines = {}
    for _, r in ipairs(records) do lines[#lines + 1] = J.encode(r) end
    local files = {
        [root .. "/" .. id .. "/notebook.json"] = meta,
        [root .. "/" .. id .. "/page-0.jsonl"] = table.concat(lines, "\n") .. (tail or "\n"),
    }
    return Sample.export(root, id, 0, label or "Read & compare <two> lines.\n", function(path)
        assert(files[path], "unexpected file: " .. path)
        return files[path]
    end, region)
end
local n = 0
local function check(ok, text) assert(ok, text); n=n+1; print("PASS: " .. text) end
local x = export{record(1)}
check(x:find("Read &amp; compare &lt;two&gt; lines.", 1, true), "truth is XML escaped")
check(x:find("0.000000 0.000000 0.000 100 -2 3", 1, true), "initial point preserves pressure and tilt")
check(x:find("1871.000000 1403.000000 1.000 200 4 -5", 1, true), "digitizer endpoints and microsecond times converted")
x = export{record(1), record(2), {k="u",a=2}}
check(x:find('xml:id="a1"',1,true) and not x:find('xml:id="a2"',1,true), "undone stroke omitted")
x = export{record(1), record(2), {k="u",a=2}, {k="r",a=2}, {k="x",a=3,ids={1}}}
check(not x:find('xml:id="a1"',1,true) and x:find('xml:id="a2"',1,true), "redo and whole-stroke erase use production replay")
x = export{record(1,"pen",1)}
check(x:find("1403.000000 0.000000",1,true), "recorded mode 1 maps through BB rotation 3")
x = export{record(1,"pen",3)}
check(x:find("0.000000 1871.000000",1,true), "recorded mode 3 maps through BB rotation 1")
local cases = {
    {"area erase", {record(1),record(2,"eraser")}},
    {"mixed orientations", {record(1),record(2,"pen",1)}},
    {"dropout", {record(1,"pen",0,true)}},
    {"ignored undo", {record(1),{k="u",a=99}}},
    {"no active ink", {record(1),{k="u",a=1}}},
}
for _, case in ipairs(cases) do check(not pcall(export,case[2]), "refuses " .. case[1]) end
check(not pcall(export,{record(1)},"two\nlines"), "refuses multiline transcription")
check(not pcall(export,{record(1)},""), "refuses empty truth")
check(not pcall(export,{record(1)},nil,""), "refuses incomplete tail without repairing source")
check(not pcall(export,{record(1)},nil,"\nbad\n"), "refuses damaged records")
local function dot(a, rawx, rawy, rot, tool)
    return J.stroke_record(a, Brush.style("fine", "M", tool or "pen", C), rot or 0, 1000,
        {{t=1000,rawx=rawx,rawy=rawy,p=100,tx=0,ty=0}}, false, {0,0,1871,1403})
end
local dots = { dot(1, 2000, 2000), dot(2, 2000, 8000) }
local region = { x=100, y=100, w=200, h=200 }
x = export(dots, nil, nil, region)
check(x:find('xml:id="a1"',1,true) and not x:find('xml:id="a2"',1,true),
      "writing-area export keeps one whole stroke and excludes the next line")
check(x:find('source-region">100 100 200 200',1,true), "crop provenance recorded")
check(not pcall(export, dots, nil, nil, {x=179,y=100,w=200,h=200}),
      "refuses even a brush edge crossing a crop boundary")
check(not pcall(export, dots, nil, nil, {x=900,y=900,w=20,h=20}), "refuses empty region")
check(not pcall(export, dots, nil, nil, {x=0,y=0,w=2000,h=20}), "refuses out-of-panel crop")
check(not pcall(export, dots, nil, nil, {x=0.5,y=0,w=100,h=20}), "refuses fractional crop")
x = export({dot(1, 2000, 2000, 1), dot(2, 8000, 2000, 1)}, nil, nil,
           {x=1100,y=100,w=200,h=200})
check(x:find('xml:id="a1"',1,true) and not x:find('xml:id="a2"',1,true),
      "sampler portrait crop follows recorded mode through physical coordinates")
local erased = {dot(1,2000,2000),dot(2,2000,8000,0,"eraser")}
x = export(erased,nil,nil,region)
check(x:find('xml:id="a1"',1,true) and not x:find('xml:id="a2"',1,true),
      "eraser wholly outside a selected line does not discard unaffected ink")
check(not pcall(export,erased), "whole-page export still refuses an area eraser")
check(not pcall(export,{dot(1,2000,2000),dot(2,2000,2000,0,"eraser")},nil,nil,region),
      "eraser inside a selected line refuses hidden-ink export")
check(not pcall(export,{dot(1,2000,2000),dot(2,3400,2000,0,"eraser")},nil,nil,region),
      "eraser center outside crop but brush overlapping it is refused")
print(string.format("PASS: %d sample-export assertions", n))

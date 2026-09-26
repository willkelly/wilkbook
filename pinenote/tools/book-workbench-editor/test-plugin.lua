-- Real LuaJIT/rapidjson and private socketpair; widget lifecycle is mocked here.
-- Native InputDialog integration is a separate runner gate.
local dir = assert(arg[1],"usage: test-plugin.lua PLUGIN-DIRECTORY")
local bundle = os.getenv("KOREADER_NATIVE_BUNDLE") or "/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03"
package.path = dir.."/?.lua;"..package.path
package.cpath = bundle.."/lib/koreader/common/?.so;"..package.cpath
local JSON,ffi = require("rapidjson"),require("ffi")
local Codec,Channel = require("editor_codec"),require("editor_channel")
ffi.cdef[[
int socketpair(int domain, int kind, int protocol, int descriptors[2]);
int pipe(int descriptors[2]);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
int setsockopt(int fd, int level, int option, const void *value, unsigned int length);
]]
local C,checks = ffi.C,0
local function check(v,why) assert(v,why); checks=checks+1 end
local function hex(s) return (s:gsub(".",function(c) return string.format("%02x",c:byte()) end)) end
local function raw(seq,s) return "reply|"..seq.."|"..hex(s) end
local function frame(seq,v) return raw(seq,JSON.encode(v)).."\n" end
local function array(v) return JSON.array(v or {}) end
local function form(request,generation,text,id)
    return {type="editor-present",protocol_version=1,request_id=request,sequence=request,
        action_id=id or "open",surface_handle="opaque-host",surface_generation=generation,
        title="Authored title",text=text or "",status="",
        actions=array({{id="save",label="Install",enabled=true},
            {id="preview",label="Completely custom",enabled=true},
            {id="host_close",label="Disabled",enabled=false}})}
end
local good = {op="present",view=1,form=form(1,1,"λ")}
local encoded = JSON.encode(good)
check(Codec.parseReply(raw(1,encoded)),"valid form array rejected")
for _,bad in ipairs({
    encoded:gsub('"protocol_version":1','"protocol_version":1.0'),
    encoded:gsub('"request_id":1','"request_id":1e0'),
    encoded:gsub('"sequence":1','"sequence":1e-999'),
    encoded:gsub('"view":1','"view":1,"\\u0076iew":1'),
    encoded:gsub('"enabled":true','"enabled":true,"enabled":false',1),
    encoded.." trailing",
    '{"op":"failure","view":1,"error":[[[[[[]]]]]]}',
    '{"op":"present","view":1,"form":{}}',
    '{"op":"failure","view":1,"error":"x","path":"/host"}',
}) do check(not Codec.parseReply(raw(1,bad)),"malformed JSON/schema accepted: "..bad) end
for _,bad in ipairs({"reply|01|7b7d","reply|0|7b7d","reply|2147483648|7b7d",
    "reply|1|FF","reply|1|f",string.rep("x",Codec.MAX_LINE+1)}) do
    check(not Codec.parseReply(bad),"malformed frame accepted")
end
for _,bad in ipairs({"\0","\192\128","\237\160\128","\244\144\128\128","\226\130"}) do
    check(not Codec.validText(bad,8192),"invalid UTF-8 accepted")
end
check(Codec.validCommand({op="open",view=1,text=string.rep("λ",4096)}),"8192 bytes rejected")
check(not Codec.validCommand({op="open",view=1,text=string.rep("λ",4097)}),"oversized input accepted")
check(not Codec.validCommand({op="open",view=1,text="",path="x"}),"host path command accepted")
check(not Codec.validCommand({op="action",view=1,text="",surface_handle="h",surface_generation=1,action_id="open"}),"UI can forge reserved open")
for _,actions in ipairs({{},array({{id="open",label="Open",enabled=true}}),
    array({{id="x",label="X",enabled=true},{id="x",label="Again",enabled=true}}),
    array({{id="x",label="X",enabled=1}}),array({{id="λ",label="X",enabled=true}})}) do
    local f = form(1,1); f.actions=actions
    check(not Codec.validForm(f),"invalid action vector accepted")
end
local empty = form(1,1); empty.actions=array()
check(Codec.validForm(empty),"empty text/actions rejected")

local Base = {}
function Base:extend(v) v.__index=v; return setmetatable(v,{__index=self}) end
function Base:new(v) v=setmetatable(v or {},{__index=self}); if v.init then v:init() end; return v end
local shown,sources,timers = {},{},{}
local UI = {}
function UI:show(w) shown[w]=true end
function UI:close(w) shown[w]=nil; if w.onCloseWidget then w:onCloseWidget() end end
function UI:insertZMQ(c) assert(not sources[c]); sources[c]=true end
function UI:removeZMQ(c) assert(sources[c]); sources[c]=nil end
function UI:scheduleIn(_,fn) timers[fn]=true end
function UI:unschedule(fn) timers[fn]=nil end
function UI:setDirty() end
local Dialog = Base:extend{}
function Dialog:init()
    self.text=self.text or self.input or ""
    self.layout_title = self.title
    self.layout_count = (self.layout_count or 0)+1
    self.title_bar={title=self.title,setTitle=function()
        error("TitleBar-only mutation bypasses InputDialog height and cached offsets")
    end}
    local buttons={}
    for _,row in ipairs(self.buttons or {}) do for _,b in ipairs(row) do
        buttons[b.id]=b
        function b:enable() self.enabled=true end
        function b:disable() self.enabled=false end
    end end
    self.button_table={getButtonById=function(_,id) return buttons[id] end}
    if self.edited_callback then self.edited_callback(true) end
end
function Dialog:reinit() self:init() end
function Dialog:getInputText() return self.text end
function Dialog:setInputText(s,edited) self.text=s; if self.edited_callback then self.edited_callback(edited) end end
function Dialog:refreshButtons() end
function Dialog:onCloseWidget() end
function Dialog:onSetRotationMode() self:reinit() end
package.loaded["ui/uimanager"]=UI
package.loaded["ui/widget/inputdialog"]=Dialog
package.loaded["ui/widget/container/widgetcontainer"]=Base
package.loaded["ui/widget/confirmbox"]={new=function(_,v) v.is_confirmation=true; return v end}
package.loaded["ui/widget/infomessage"]={new=function(_,v) return v end}
package.loaded["ui/font"]={getFace=function() return {} end}
package.loaded.gettext=function(s) return s end
local original=os.getenv("BOOK_WORKBENCH_EDITOR_UI_FD")
C.unsetenv("BOOK_WORKBENCH_EDITOR_UI_FD")
check(assert(loadfile(dir.."/main.lua"))().disabled,"enabled without donated FD")
for _,bad in ipairs({"2","03","3.0","1e1","-1","2147483648"}) do
    C.setenv("BOOK_WORKBENCH_EDITOR_UI_FD",bad,1)
    check(assert(loadfile(dir.."/main.lua"))().disabled,"accepted invalid FD")
end
local function fixture()
    local fds=ffi.new("int[2]"); assert(C.socketpair(1,1,0,fds)==0)
    C.setenv("BOOK_WORKBENCH_EDITOR_UI_FD",tostring(tonumber(fds[0])),1)
    local Class=assert(loadfile(dir.."/main.lua"))()
    check(C.fcntl(fds[0],1)%2==1,"FD not CLOEXEC at module load")
    -- Native KOReader supplies its root widget as dialog when creating plugins.
    -- It must not be mistaken for this plugin's own editable InputDialog.
    local owner={native_reader_owner=true}
    local p=Class:new{dialog=owner,ui={menu={registerToMainMenu=function() end}}}
    p:_open()
    check(p.editor_dialog and p.editor_dialog~=owner and p.dialog==owner,
        "injected ReaderUI owner prevented open or was overwritten")
    local peer=tonumber(fds[1])
    local buffer=ffi.new("char[?]",200000)
    local function receive()
        local n=C.recv(peer,buffer,200000,64)
        if n <= 0 then return nil end
        local data=ffi.string(buffer,n)
        local seq,hexed=data:match("^command|([0-9]+)|([0-9a-f]+)\n$")
        assert(seq,"expected one command: "..data)
        return tonumber(seq),JSON.decode(hexed:gsub("..",function(h) return string.char(tonumber(h,16)) end))
    end
    local function reply(seq,payload,fragment)
        local line=frame(seq,payload)
        if fragment then
            assert(C.send(peer,line,fragment,16384)==fragment); p.channel:waitEvent()
            assert(C.send(peer,line:sub(fragment+1),#line-fragment,16384)==#line-fragment)
        else assert(C.send(peer,line,#line,16384)==#line) end
        for _=1,20 do if not sources[p.channel] then break end; p.channel:waitEvent() end
    end
    return p,peer,receive,reply
end
local function start(p,receive,reply,text)
    local seq,cmd=receive(); check(cmd.op=="hello","hello missing")
    reply(seq,{op="ready",protocol_version=1,max_text_bytes=8192,max_actions=8},7)
    seq,cmd=receive(); check(cmd.op=="open","open missing")
    reply(seq,{op="present",view=cmd.view,form=form(1,1,text)})
    check(p.editor_dialog:getInputText()==text,"initial form not rendered")
    check(not p.registered and next(timers)==nil,"idle editor retained polling or request timer")
end
local p,peer,receive,reply=fixture()
start(p,receive,reply,"seed")
local root_owner=p.dialog
check(not p.editor_dialog.save_callback,"native privileged Save installed")
local save=p.editor_dialog.button_table:getButtonById("authored_1")
check(save.text=="Install" and save.enabled,"authored button missing")
check(not p.editor_dialog.button_table:getButtonById("authored_3").enabled,"disabled action enabled")
save.callback()
local seq,cmd=receive()
check(p.registered and timers[p.pending.timeout],"request did not re-register polling/deadline")
check(cmd.op=="action" and cmd.action_id=="save","authored Save was privileged")
check(not p.confirmation,"authored Install label opened trusted confirmation")
check(not p:_action("preview"),"second pending action admitted")
p.editor_dialog:setInputText("later edit",true)
reply(seq,{op="present",view=p.view,form=form(2,1,"reply replacing text","save")})
check(p.editor_dialog:getInputText()=="later edit","late reply overwrote edit")
check(p.form.text=="reply replacing text","late reply did not update form metadata")
p.editor_dialog.button_table:getButtonById("authored_2").callback()
seq,cmd=receive()
check(cmd.action_id=="preview" and cmd.text=="later edit","generic action lost text")
reply(seq,{op="present",view=p.view,form=form(3,1,"transformed","preview")})
check(p.editor_dialog:getInputText()=="transformed","unedited action result not applied")
p.editor_dialog:setInputText("retained through rotation",true)
p:_action("save"); local oldseq,oldcmd=receive()
local oldbutton=p.editor_dialog.button_table:getButtonById("authored_1")
p.editor_dialog:onSetRotationMode(1)
local openseq,opencmd=receive()
check(opencmd.op=="open" and opencmd.view>oldcmd.view,"rotation did not renew view")
oldbutton.callback()
check(receive()==nil,"retired button callback dispatched")
reply(oldseq,{op="present",view=oldcmd.view,form=form(4,1,"stale","save")})
check(p.pending and p.pending.sequence==openseq,"stale response retired new pending")
reply(openseq,{op="present",view=opencmd.view,form=form(5,2,"new view")})
check(p.editor_dialog:getInputText()=="retained through rotation","rotation overwrote draft")
p:_action("save"); seq,cmd=receive()
UI:close(p.editor_dialog)
check(not p.editor_dialog and p.dialog==root_owner,"Close cleared native owner")
local _,close=receive()
check(close.op=="close" and next(sources)==nil and next(timers)==nil,"closed dialog polling/timer remains")
local delayed=frame(seq,{op="present",view=cmd.view,form=form(6,2,"closed reply","save")})
assert(C.send(peer,delayed,#delayed,16384)==#delayed)
p:_open(); openseq,opencmd=receive()
reply(openseq,{op="present",view=opencmd.view,form=form(7,3,"reopened")})
check(p.editor_dialog:getInputText()=="retained through rotation","reopen overwrote retained draft")
check(p.dialog==root_owner and p.editor_dialog~=root_owner,"reopen replaced native owner")
check(not p.disconnected,"queued closed reply disconnected reopened view")
p:_action("save"); seq,cmd=receive()
reply(seq,{op="confirmation",view=p.view,token="host-token",kind="install",summary="Trusted revision summary"})
check(p.confirmation and p.confirmation_box.is_confirmation,"host confirmation not displayed")
check(not p.registered and next(timers)==nil,"human confirmation retained 20 Hz polling")
local confirm=p.confirmation_box
confirm.ok_callback(); seq,cmd=receive()
check(p.registered and timers[p.pending.timeout],"confirmation decision did not resume polling/deadline")
check(cmd.op=="decision" and cmd.accept and cmd.token=="host-token","host confirmation not correlated")
confirm.ok_callback(); check(receive()==nil,"confirmation callback replay sent decision")
reply(seq,{op="present",view=p.view,form=form(8,3,"authority text","save")})
check(p.editor_dialog:getInputText()=="authority text","confirmed action presentation was not applied")
p:_action("preview"); seq,cmd=receive()
reply(seq,{op="confirmation",view=p.view,token="cancel-token",kind="recovery",summary="Recover"})
local retired=p.confirmation_box
p.editor_dialog:setInputText("edit after prompt",true)
local decisionseq,decision=receive()
check(decision.op=="decision" and not decision.accept,"edit did not cancel confirmation")
retired.ok_callback(); check(receive()==nil,"retired confirmation can install")
reply(decisionseq,{op="failure",view=p.view,error="cancelled"})
check(p.editor_dialog:getInputText()=="edit after prompt","failure overwrote draft")
p:onCloseDocument(); receive(); C.close(peer)
check(p.dialog==root_owner and not p.editor_dialog,"teardown cleared native owner")
check(next(sources)==nil and next(timers)==nil,"teardown polling/timer leak")
local q,qpeer,qreceive,qreply=fixture()
start(q,qreceive,qreply,"")
q:_action("save"); seq,cmd=qreceive()
local wrong=form(2,1,"wrong","preview")
qreply(seq,{op="present",view=q.view,form=wrong})
check(q.disconnected and q.editor_dialog:getInputText()=="","uncorrelated action response accepted")
q:onCloseDocument(); C.close(qpeer)
local r,rpeer,rreceive,rreply=fixture()
start(r,rreceive,rreply,"timeout draft")
r:_action("save"); rreceive()
local timeout=r.pending.timeout
timeout()
check(r.disconnected and r.editor_dialog:getInputText()=="timeout draft" and next(timers)==nil,"timeout lost draft or timer")
r:onCloseDocument(); C.close(rpeer)
-- Actual asynchronous writes, partial reads, EOF and descriptor type checks.
local fds=ffi.new("int[2]"); assert(C.pipe(fds)==0)
check(not Channel.prepareFD(tonumber(fds[0])),"pipe accepted as authority socket")
C.close(fds[1])
local s,speer,sreceive,sreply=fixture()
start(s,sreceive,sreply,"EOF draft")
C.close(speer)
check(not s.registered and not s.disconnected,"idle endpoint was polled for EOF")
s:_action("save")
if not s.disconnected then s.channel:waitEvent() end
check(s.disconnected and s.editor_dialog:getInputText()=="EOF draft" and next(sources)==nil,"EOF lifecycle failed")
s:onCloseDocument()
local t,tpeer,treceive,treply=fixture()
local hello_seq=treceive()
UI:close(t.editor_dialog); treceive()
check(next(sources)==nil and next(timers)==nil,"Close during hello retained polling")
t:_open()
local fresh_hello,hello=treceive()
check(hello.op=="hello" and fresh_hello>hello_seq,"retired handshake was reused")
treply(hello_seq,{op="ready",protocol_version=1,max_text_bytes=8192,max_actions=8})
check(t.pending.sequence==fresh_hello,"old handshake completed reopened view")
treply(fresh_hello,{op="ready",protocol_version=1,max_text_bytes=8192,max_actions=8})
local fresh_open,open=treceive()
treply(fresh_open,{op="present",view=open.view,form=form(1,2,"initial after reopen")})
check(t.editor_dialog:getInputText()=="initial after reopen","untouched placeholder incorrectly preserved")
t:_action("save"); seq,cmd=treceive()
t.editor_dialog:setInputText("away",true); t.editor_dialog:setInputText("initial after reopen",true)
treply(seq,{op="present",view=t.view,form=form(2,2,"different result","save")})
check(t.editor_dialog:getInputText()=="initial after reopen","edit-away-and-back was overwritten")
t:_action("preview"); seq,cmd=treceive()
t.editor_dialog:setInputText("late confirmation edit",true)
treply(seq,{op="confirmation",view=t.view,token="late",kind="install",summary="Late"})
local late_seq,declined=treceive()
check(declined.op=="decision" and not declined.accept and not t.confirmation,"late confirmation not declined")
treply(late_seq,{op="present",view=t.view,form=form(3,2,"late result","preview")})
check(t.editor_dialog:getInputText()=="late confirmation edit","declining late confirmation erased edits")
t:onCloseDocument(); treceive(); C.close(tpeer)

local u,upeer,ureceive,ureply=fixture()
local first_loading=u.editor_dialog
local loading_close=first_loading.button_table:getButtonById("host_close").callback
ureceive() -- initial hello
loading_close()
local _,closed_loading=ureceive()
check(not u.editor_dialog and closed_loading.op=="close","loading Close did not close its own widget")
u:_open()
loading_close()
check(u.editor_dialog and ureceive()~=nil,"retired loading Close closed reopened widget")
check(not first_loading:onCloseDialog() and u.editor_dialog,"retired Back closed reopened widget")
local hs=u.pending.sequence
ureply(hs,{op="ready",protocol_version=1,max_text_bytes=8192,max_actions=8})
local os,oc=ureceive()
local titled=form(1,1,"layout draft")
titled.title="First title line\n"..string.rep("long title ",9)
ureply(os,{op="present",view=oc.view,form=titled})
check(u.editor_dialog.layout_title==titled.title and u.editor_dialog.title_bar.title==titled.title,
    "multiline authored title was not measured as the displayed title")
local layouts=u.editor_dialog.layout_count
u:_controls(); u:_controls()
check(u.editor_dialog.layout_count==layouts,"identical control updates rebuilt the title/layout")
u:_action("save"); local us,uc=ureceive()
check(u.editor_dialog.layout_title==titled.title.." — waiting",
    "waiting suffix bypassed native title/layout measurement")
ureply(us,{op="failure",view=uc.view,error="test rejection"})
check(u.editor_dialog.layout_title=="Operation failed — draft retained"
    and u.editor_dialog:getInputText()=="layout draft","failure title bypassed layout or lost text")
check(not u.registered,"failed action retained idle polling")
local former=u.editor_dialog
local old_close=former.button_table:getButtonById("host_close").callback
check(former:onCloseDialog() and not u.editor_dialog,"native Back did not close the editor")
ureceive()
u:_open(); ureceive()
local reopened_widget=u.editor_dialog
old_close()
check(u.editor_dialog==reopened_widget and shown[reopened_widget],"old host Close closed a later editor")
u:_new_view(); ureceive()
u:_new_view(); ureceive() -- same waiting title, but another view still needs new callbacks
check(u.editor_dialog:onCloseDialog() and not u.editor_dialog,"Back failed after repeated loading rotations")
ureceive()
u:onCloseDocument(); C.close(upeer)

do
    local editor,fd,get,put=fixture()
    start(editor,get,put,"author draft")
    editor:_action("preview")
    local request=get()
    -- An author edit after submission must survive the entire candidate lifetime.
    editor.editor_dialog:setInputText("author late edit",true)
    put(request,{op="preview",view=editor.view,preview_view=20,token="candidate-one",form=form(1,1,"candidate draft")})
    local candidate=assert(editor.preview_editor)
    check(candidate.view~=editor.view and candidate.form~=editor.form,"preview reused author view/form")
    check(candidate.editor_dialog.title:find("Disposable preview",1,true),"trusted preview chrome missing")
    check(not editor.registered and next(timers)==nil,"human preview idle polls or times out")
    check(not editor:_action("save"),"author accepted action while preview outstanding")
    check(not editor.editor_dialog.button_table:getButtonById("authored_1").enabled,"author buttons active under preview")
    candidate:_action("save")
    local seq,command=get()
    check(command.op=="preview-action" and command.token=="candidate-one" and command.view==20,
        "candidate action lost private lifetime")
    check(editor.registered and timers[candidate.pending.timeout],"candidate action missing poll/deadline")
    candidate.editor_dialog:setInputText("away",true)
    candidate.editor_dialog:setInputText("candidate draft",true)
    put(seq,{op="preview",view=20,preview_view=20,token="candidate-one",form=form(2,1,"transformed candidate","save")})
    check(candidate.editor_dialog:getInputText()=="candidate draft","candidate late reply overwrote edit-away/back")
    check(editor.editor_dialog:getInputText()=="author late edit","candidate action overwrote author draft")
    check(not editor.registered and next(timers)==nil,"candidate idle kept channel registered")
    local old_finish=candidate.editor_dialog.button_table:getButtonById("host_preview_finish").callback
    local old_cancel=candidate.editor_dialog.button_table:getButtonById("host_preview_cancel").callback
    local old_dialog=candidate.editor_dialog
    old_finish()
    seq,command=get()
    check(command.op=="preview-finish" and command.accept and command.token=="candidate-one", "Finish not trusted/correlated")
    check(not editor.preview_editor and editor.pending.origin_action=="preview","Finish lost author origin")
    put(seq,{op="present",view=editor.view,form=form(2,1,"submitted author draft","preview")})
    check(editor.editor_dialog:getInputText()=="author late edit","Finish replaced author late edit")
    editor:_action("preview"); seq=get()
    put(seq,{op="preview",view=editor.view,preview_view=21,token="candidate-two",form=form(1,1,"second candidate")})
    local second=editor.preview_editor
    old_finish(); old_cancel(); old_dialog:onCloseDialog()
    check(editor.preview_editor==second and get()==nil,"stale preview chrome affected replacement")
    second:_action("save"); local retired_seq=get()
    second.editor_dialog.button_table:getButtonById("host_preview_cancel").callback()
    seq,command=get()
    check(command.op=="preview-finish" and not command.accept,"Cancel did not supersede pending action")
    put(retired_seq,{op="preview",view=21,preview_view=21,token="candidate-two",form=form(2,1,"retired candidate","save")})
    check(editor.pending and editor.pending.sequence==seq,"late candidate reply consumed author continuation")
    put(seq,{op="present",view=editor.view,form=form(3,1,"author cancel result","preview")})
    editor:_action("preview"); seq=get()
    put(seq,{op="preview",view=editor.view,preview_view=22,token="candidate-three",form=form(1,1,"failure draft")})
    local failed=editor.preview_editor
    failed:_action("save"); seq=get()
    put(seq,{op="preview-failure",view=22,token="candidate-three",error="candidate exited"})
    check(failed.last_error and failed.editor_dialog:getInputText()=="failure draft","candidate error lost draft")
    check(not failed.editor_dialog.button_table:getButtonById("host_preview_finish").enabled,"failed candidate can Finish")
    check(not failed:_action("save"),"failed candidate can dispatch more actions")
    check(not editor.registered and next(timers)==nil,"failed candidate idle retained polling")
    check(failed.editor_dialog:onCloseDialog(),"candidate native Back failed")
    seq,command=get()
    check(command.op=="preview-finish" and not command.accept,"candidate Back closed author instead of cancelling")
    put(seq,{op="present",view=editor.view,form=form(4,1,"author after error","preview")})
    check(editor.editor_dialog and not editor.preview_editor,"candidate Back lost main editor")
    editor:onCloseDocument(); get(); C.close(fd)
    check(next(sources)==nil and next(timers)==nil,"preview lifecycle leaked polls/timers")
end

do
    local editor,fd,get,put=fixture()
    start(editor,get,put,"chain source")
    editor:_action("preview")
    local seq=get()
    local root=editor.pending
    put(seq,{op="preview",view=editor.view,preview_view=31,token="chain-1",form=form(1,1,"candidate")})
    editor.preview_editor.editor_dialog.button_table:getButtonById("host_preview_finish").callback()
    seq=get()
    check(editor.pending.origin==root and editor.pending.form==root.form,"Finish did not retain root action/form")
    put(seq,{op="confirmation",view=editor.view,token="chain-install",kind="install",summary="Install"})
    check(editor.confirmation and editor.confirmation.origin==root,"chained confirmation rejected/lost origin")
    editor.confirmation_box.ok_callback(); seq=get()
    check(editor.pending.origin==root,"decision accumulated/lost root origin")
    put(seq,{op="preview",view=editor.view,preview_view=32,token="chain-2",form=form(1,1,"next candidate")})
    check(editor.preview_origin==root,"decision-to-preview rejected original action")
    editor.editor_dialog:setInputText("late chain edit",true)
    editor.preview_editor.editor_dialog.button_table:getButtonById("host_preview_finish").callback()
    seq=get()
    put(seq,{op="confirmation",view=editor.view,token="chain-stale-install",kind="install",summary="Stale"})
    local decline_seq,decline=get()
    check(not editor.confirmation and decline.op=="decision" and not decline.accept,"late chained proposal not declined")
    check(editor.pending.origin==root and editor.pending.serial==root.serial,"chained decline reset source edit serial")
    put(decline_seq,{op="present",view=editor.view,form=form(2,1,"final authored transform","preview")})
    check(not editor.disconnected and editor.form.text=="final authored transform","chain final response rejected")
    check(editor.editor_dialog:getInputText()=="late chain edit","chain final response replaced late edit")
    editor:_action("preview"); seq=get()
    put(seq,{op="preview",view=editor.view,preview_view=33,token="wrong-form-chain",form=form(1,1,"candidate")})
    editor.preview_editor.editor_dialog.button_table:getButtonById("host_preview_finish").callback(); seq=get()
    put(seq,{op="present",view=editor.view,form=form(3,1,"wrong final action","save")})
    check(editor.disconnected and editor.editor_dialog:getInputText()=="late chain edit",
        "continuation accepted another original action")
    editor:onCloseDocument(); get(); C.close(fd)
    check(next(sources)==nil and next(timers)==nil,"continuation chain leaked polls/timers")
end

-- Exercise real backpressure and partial writes of the largest escaped text.
-- No busy loop is required in production: each waitEvent spends one budget.
local pair=ffi.new("int[2]"); assert(C.socketpair(1,1,0,pair)==0)
local small=ffi.new("int[1]",1024)
assert(C.setsockopt(pair[0],1,7,small,4)==0)
local ch=assert(Channel:new{fd=tonumber(pair[0]),receive=function() error("unexpected reply") end})
local big={op="open",view=1,text=string.rep("\1",8192)}
local wire=assert(Codec.encodeCommand(1,big))
check(ch:send(1,big) and ch.bytes>0,"large write did not encounter backpressure")
local collected,buf="",ffi.new("char[?]",8192)
for _=1,500 do
    local n=C.recv(pair[1],buf,8192,64)
    if n>0 then collected=collected..ffi.string(buf,n) end
    if #collected==#wire then break end
    ch:waitEvent()
end
check(collected==wire and ch.bytes==0,"partial writes lost/repeated bytes")
check(ch:send(2,big) and ch:send(3,big) and ch:send(4,big) and ch:send(5,big),"bounded output queue rejected early")
check(not ch:send(6,big),"output queue exceeded four frames")
ch:stop(); C.close(pair[1])
check(next(sources)==nil and next(timers)==nil,"final polling or deadline leak")
if original then C.setenv("BOOK_WORKBENCH_EDITOR_UI_FD",original,1) else C.unsetenv("BOOK_WORKBENCH_EDITOR_UI_FD") end
print("PASS: "..checks.." generic editor codec/socket/FSM assertions")

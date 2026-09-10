import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qinglong_flutter/shared/code_language.dart';
import 'package:qinglong_flutter/shared/highlighting_code_controller.dart';

const file2 = '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:100%;height:100%;background:#000;color:#fff;overflow:hidden;font-family:system-ui,-apple-system,sans-serif}
body{display:flex;align-items:center;justify-content:center}
#out{width:100%;height:100%;background:transparent;border:0;display:flex;flex-direction:column;align-items:center;justify-content:center;user-select:none;-webkit-user-select:none;touch-action:none;cursor:default}
#hint{font-size:3vmin;color:#666;letter-spacing:2px;text-align:center;line-height:1.9}
#st{font-size:3.2vmin;color:#ffd54f;min-height:1.6em;margin-top:4%;letter-spacing:1px}
</style>
</head>
<body>
<div id="out">
  <div id="st">待命</div>
  <div id="hint">滑动四方向 · 双击重开<br>长按撤销 · 双指轻点暂停</div>
</div>
<script>
var st=document.getElementById('st');
var lastT=[], lastTapAt=0, pressTimer=null, pressStart=0, touchCount=0;
function send(obj){
  st.textContent='发送 '+obj.type+(obj.dir?' '+obj.dir:'');
  try{ if(window.aiSend) aiSend('game',obj); else st.textContent='无aiSend'; }catch(e){ st.textContent='发送异常'; }
}
function resetSt(){ setTimeout(function(){ st.textContent='待命'; },900); }
function emit(d){ send({type:'move',dir:d}); resetSt(); }
var out=document.getElementById('out');
out.addEventListener('touchstart',function(e){
  e.preventDefault();
  touchCount=e.touches.length;
  var t=e.changedTouches[0];
  lastT=[t.clientX,t.clientY];
  pressStart=Date.now();
  if(touchCount===1){ pressTimer=setTimeout(function(){ if(touchCount===1){ send({type:'undo'}); st.textContent='撤销'; resetSt(); } },1600); }
},{passive:false});
out.addEventListener('touchmove',function(e){ e.preventDefault(); },{passive:false});
out.addEventListener('touchend',function(e){
  e.preventDefault();
  clearTimeout(pressTimer); pressTimer=null;
  var d=Date.now()-pressStart;
  if(touchCount===2){ send({type:'pause'}); st.textContent='暂停/继续'; resetSt(); touchCount=0; return; }
  if(d<500 && lastT.length){
    var t=e.changedTouches[0];
    var dx=t.clientX-lastT[0], dy=t.clientY-lastT[1];
    if(Math.max(Math.abs(dx),Math.abs(dy))<12){
      var now=Date.now();
      if(now-lastTapAt<300){ send({type:'restart'}); st.textContent='重新开始'; resetSt(); lastTapAt=0; }
      else lastTapAt=now;
    } else if(Math.abs(dx)>Math.abs(dy)){ emit(dx>0?'right':'left'); }
    else { emit(dy>0?'down':'up'); }
  }
  touchCount=0;
},{passive:false});
window.onAiMessage=function(data,from){
  if(data&&data.type==='state') st.textContent=(data.paused?'已暂停':'运行中')+(data.over?'·结束':'');
};
</script>
</body>
</html>''';

void main() {
  testWidgets('exact file2 html mixed highlighting colors', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(
      builder: (context) {
        ctx = context;
        return const SizedBox.shrink();
      },
    ));

    final ctrl = HighlightingCodeController(
      language: modeForLanguage('html'),
      languageName: 'html',
      text: file2,
    );
    final span = ctrl.buildTextSpan(context: ctx);

    int countColored(TextSpan s) {
      var n = s.style?.color != null ? 1 : 0;
      for (final child in s.children ?? const <InlineSpan>[]) {
        if (child is TextSpan) n += countColored(child);
      }
      return n;
    }

    final total = countColored(span);
    debugPrint('exact file2 total colored=$total');
    expect(total, greaterThan(40));
  });
}

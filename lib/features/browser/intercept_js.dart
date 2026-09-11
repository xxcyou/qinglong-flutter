/// 注入页面的抓包 + 改包运行时（脚本钩子）。
///
/// 为什么钩子写在 JS 里：Android 的 WebView 没有"网络层拦截"这种东西
/// （`shouldInterceptRequest` 只看得到主资源和子资源，拿不到 fetch/XHR 的请求体，
/// 更没法改 POST 载荷）。真正能改到请求的位置只有一个——页面自己的
/// `fetch` / `XMLHttpRequest`。所以这里接管这两个入口，在"页面调它"和"真的发出去"
/// 之间插一层，把请求/响应交给脚本处理。
///
/// 为什么是脚本而不是"匹配规则"：改包的花样是无穷的（重算签名、按上一包的
/// 返回决定这一包、解 JSON 改一个深层字段再塞回去……），任何字段式规则都会
/// 在真实站点前面撞墙。脚本就是抓包工具那一套，想改什么就写什么；而这个能力
/// 本来就是给 AI 用的，AI 写 JS 比拼 when/then 更自然。
///
/// 脚本约定（脚本体里定义这两个函数，缺哪个都行）：
///
/// ```js
/// function onRequest(req) {
///   // req.url / req.method / req.headers（普通对象）/ req.body（字符串）/ req.kind
///   // 直接改字段即可；另外两个特殊字段：
///   //   req.block = true;                    整包拦掉
///   //   req.mock  = {status:200, body:'{}'}; 不发出去，直接假返回
/// }
/// function onResponse(res) {
///   // res.status / res.headers / res.body / res.url / res.method / res.request
///   // 直接改字段即可。
/// }
/// ```
///
/// 每个脚本还拿到一个 `QL`：`QL.log(...)` 打到浏览器窗口的日志页，
/// `QL.state` 是这个脚本自己的暂存对象（同一次页面生命周期内保持）。
///
/// 生命周期：每次导航后 JS 环境重建，所以 [interceptJs] 会被反复注入；
/// `__qlHooked` 保证只装一次，脚本表由 `__qlSetScripts` 单独推。
///
/// 边界（老实说清楚，免得排查时怀疑脚本写错了）：
/// - 只覆盖 fetch / XHR。`<img src>`、表单同步提交、Service Worker 里发的请求
///   不经过这里；
/// - 注入发生在导航之后，页面在注入之前那几毫秒里发出的请求抓不到；
/// - XHR 的返回体改写靠"抢先注册的 readystatechange 监听 + 覆盖实例属性"，
///   对绝大多数页面有效；但页面用了 responseType=blob/arraybuffer 时改
///   responseText 没有意义，这种情况会在改写说明里注明。
const String interceptJs = r'''
(function(){
  if (window.__qlHooked) return; window.__qlHooked = true;
  var seq = 0;
  var nseq = 100000;
  var scripts = [];
  var nativeFetches = {};
  window.__qlNativeCallback = function(nid, data){
    var p = nativeFetches[nid];
    if (!p) return;
    delete nativeFetches[nid];
    if (data && data.error) p.reject(new Error(data.error));
    else p.resolve(data || {});
  };
  function nativeFetch(ctx){
    return new Promise(function(resolve, reject){
      var nid = 'nf' + (++nseq);
      nativeFetches[nid] = {resolve: resolve, reject: reject};
      send({t:'native_req', id:nid, method:ctx.method, url:ctx.url,
            headers:ctx.headers||{}, body:s(ctx.body), ua:navigator.userAgent});
      setTimeout(function(){
        var p = nativeFetches[nid];
        if (!p) return;
        delete nativeFetches[nid];
        reject(new TypeError('Failed to fetch (native timeout)'));
      }, 60000);
    });
  }
  function fmtHdrs(h){
    var a = [];
    if (!h) return '';
    try {
      if (typeof h.forEach === 'function' && !Array.isArray(h)) {
        h.forEach(function(v, k){ a.push(s(k) + ': ' + s(v)); });
      } else {
        for (var k in h) { if (Object.prototype.hasOwnProperty.call(h, k)) a.push(s(k) + ': ' + s(h[k])); }
      }
    } catch(e){}
    return a.join('\n').slice(0, 8000);
  }

  function send(o){ try { QLBridge.postMessage(JSON.stringify(o)); } catch(e){} }
  function s(v){ return v == null ? '' : String(v); }
  // 头表压成一行行 `k: v`，Dart 侧原样展示（顺序保持发出的顺序）。
  // 敏感头不在这里过滤：抓包面板就是给用户自己看的，删了反而查不了问题。
  function hdr(h){
    if (!h) return '';
    var a = [];
    try {
      if (typeof h.forEach === 'function' && !Array.isArray(h)) {
        h.forEach(function(v, k){ a.push(s(k) + ': ' + s(v)); });
      } else {
        for (var k in h) {
          if (Object.prototype.hasOwnProperty.call(h, k)) {
            a.push(s(k) + ': ' + s(h[k]));
          }
        }
      }
    } catch(e){}
    return a.join('\n').slice(0, 8000);
  }
  function hit(id, acts){ send({t:'hit', id:id, acts:acts}); }
  function serr(id, msg){ send({t:'serr', id:id, msg:s(msg).slice(0,600)}); }

  // 每个脚本的门面：日志 + 自己的暂存对象。
  function makeApi(rec){
    return {
      id: rec.id,
      name: rec.name,
      state: {},
      log: function(){
        var text = Array.prototype.map.call(arguments, function(v){
          if (v != null && typeof v === 'object') {
            try { return JSON.stringify(v); } catch(e){ return String(v); }
          }
          return String(v);
        }).join(' ');
        send({t:'log', level:'log', text:'[' + rec.name + '] ' + text.slice(0,4000)});
      }
    };
  }

  // 编译脚本表。某条编译失败只废掉它自己，别的照跑。
  window.__qlSetScripts = function(list){
    scripts = [];
    (list||[]).forEach(function(it){
      var rec = {
        id: it.id, name: s(it.name) || ('脚本' + it.id),
        enabled: it.enabled !== false, onRequest: null, onResponse: null
      };
      if (rec.enabled) {
        try {
          var factory = new Function('QL',
            s(it.code) + '\n;return {' +
            'onRequest: (typeof onRequest === "function") ? onRequest : null,' +
            'onResponse: (typeof onResponse === "function") ? onResponse : null};');
          var api = factory(makeApi(rec)) || {};
          rec.onRequest = api.onRequest || null;
          rec.onResponse = api.onResponse || null;
          if (!rec.onRequest && !rec.onResponse) {
            serr(rec.id, '脚本里没有 onRequest / onResponse，不会被调用');
          }
        } catch(e) {
          serr(rec.id, '编译失败：' + String(e));
        }
      }
      scripts.push(rec);
    });
  };

  // 调试用：看页面里到底装了什么。
  window.__qlScripts = function(){
    return scripts.map(function(r){
      return {id:r.id, name:r.name, enabled:r.enabled,
              req:!!r.onRequest, res:!!r.onResponse};
    });
  };

  // ---- 工具 ----------------------------------------------------------
  function textOf(b){
    try {
      if (b == null) return '';
      if (typeof b === 'string') return b;
      if (b instanceof URLSearchParams) return b.toString();
      if (typeof FormData !== 'undefined' && b instanceof FormData) {
        var a=[]; b.forEach(function(v,k){ a.push(k+'='+v); }); return a.join('&');
      }
      return '[' + ((b.constructor && b.constructor.name) || typeof b) + ']';
    } catch(e){ return ''; }
  }
  function headersToObj(h){
    var out = {};
    try {
      if (!h) return out;
      if (typeof Headers !== 'undefined' && h instanceof Headers) {
        h.forEach(function(v,k){ out[k] = v; }); return out;
      }
      if (Array.isArray(h)) { h.forEach(function(p){ out[p[0]] = p[1]; }); return out; }
      for (var k in h) out[k] = h[k];
    } catch(e){}
    return out;
  }
  // 请求头专用：JS 看得见的头 + 浏览器自己会加的那几个（标注"浏览器自动加"）。
  //
  // 为什么要这么干：页面写 fetch('/api') 不带 headers 时，ctx.headers 是空的，
  // 但真正发出去的请求带着 UA、Accept、Referer、Cookie——照抄 ctx.headers 去写
  // 脚本一定跑不通（少了 Cookie 直接 401）。JS 层拿不到真实值，但这几个头的值
  // 本来就能从 navigator/location/document.cookie 推出来，推出来标明来源，
  // 比给一个空的请求头有用得多。
  function reqHdr(h){
    var lines = hdr(h);
    var seen = {};
    try {
      var obj = headersToObj(h);
      for (var k in obj) seen[String(k).toLowerCase()] = 1;
    } catch(e){}
    var guess = [];
    function add(name, value){
      if (!value) return;
      if (seen[name]) return;
      guess.push(name + ': ' + value + '    # 浏览器自动加');
    }
    try { add('user-agent', navigator.userAgent); } catch(e){}
    try { add('referer', location.href); } catch(e){}
    try { add('origin', location.origin); } catch(e){}
    // document.cookie 读不到 HttpOnly，所以这里只是"至少有这些"；
    // 完整的（含 HttpOnly）用 browser_cookies get 拿。
    try { add('cookie', document.cookie); } catch(e){}
    if (guess.length === 0) return lines;
    var tail = guess.join('\n');
    return lines ? (lines + '\n' + tail) : tail;
  }
  function rawHeadersToObj(raw){
    var out = {};
    s(raw).split(/\r?\n/).forEach(function(line){
      var i = line.indexOf(':');
      if (i > 0) out[line.slice(0,i).trim()] = line.slice(i+1).trim();
    });
    return out;
  }
  function jstr(o){ try { return JSON.stringify(o||{}); } catch(e){ return ''; } }

  // 改了什么，靠"跑前跑后各拍一张"比出来——脚本可以任意改字段，
  // 没法靠动作名申报。
  function snapReq(c){
    return {url:c.url, method:c.method, headers:jstr(c.headers), body:s(c.body)};
  }
  function diffReq(b, c){
    var acts = [];
    if (b.url !== c.url) acts.push('改地址');
    if (b.method !== c.method) acts.push('改方法');
    if (b.headers !== jstr(c.headers)) acts.push('改请求头');
    if (b.body !== s(c.body)) acts.push('改请求体');
    return acts;
  }
  function snapRes(r){
    return {status:Number(r.status), headers:jstr(r.headers), body:s(r.body)};
  }
  function diffRes(b, r){
    var acts = [];
    if (b.status !== Number(r.status)) acts.push('改状态码');
    if (b.headers !== jstr(r.headers)) acts.push('改返回头');
    if (b.body !== s(r.body)) acts.push('改返回体');
    return acts;
  }

  // ---- 跑请求钩子 ----------------------------------------------------
  function runRequest(ctx){
    var base = snapReq(ctx);
    var blocked = false, mock = null;
    for (var i=0;i<scripts.length;i++){
      var r = scripts[i];
      if (!r.enabled || !r.onRequest) continue;
      var before = snapReq(ctx);
      try {
        var out = r.onRequest(ctx);
        // 允许 return 一个对象来覆盖字段（有人习惯这么写）。
        if (out && typeof out === 'object' && out !== ctx) {
          for (var k in out) ctx[k] = out[k];
        }
      } catch(e) { serr(r.id, 'onRequest 出错：' + String(e)); continue; }
      var acts = diffReq(before, ctx);
      if (ctx.block === true) { blocked = true; acts.push('拦截'); }
      if (ctx.mock) { mock = ctx.mock; acts.push('假返回'); }
      if (acts.length) hit(r.id, acts.join('、'));
      if (blocked || mock) break;
    }
    var total = diffReq(base, ctx);
    if (blocked) total.push('拦截');
    if (mock) total.push('假返回');
    return {
      acts: total, blocked: blocked, mock: mock,
      urlChanged: base.url !== ctx.url,
      methodChanged: base.method !== ctx.method,
      headersChanged: base.headers !== jstr(ctx.headers),
      bodyChanged: base.body !== s(ctx.body)
    };
  }

  // ---- 跑响应钩子 ----------------------------------------------------
  function runResponse(res){
    var base = snapRes(res);
    for (var i=0;i<scripts.length;i++){
      var r = scripts[i];
      if (!r.enabled || !r.onResponse) continue;
      var before = snapRes(res);
      try {
        var out = r.onResponse(res);
        if (out && typeof out === 'object' && out !== res) {
          for (var k in out) res[k] = out[k];
        }
      } catch(e) { serr(r.id, 'onResponse 出错：' + String(e)); continue; }
      var acts = diffRes(before, res);
      if (acts.length) hit(r.id, acts.join('、'));
    }
    return {
      acts: diffRes(base, res),
      statusChanged: base.status !== Number(res.status),
      headersChanged: base.headers !== jstr(res.headers),
      bodyChanged: base.body !== s(res.body)
    };
  }

  // ------------------------------------------------------------ fetch
  var of = window.fetch;
  window.fetch = async function(input, init){
    var id = ++seq;
    var t0 = Date.now();
    init = init || {};
    var isReq = (typeof Request !== 'undefined') && (input instanceof Request);
    var hadHeaders = !!(init.headers || (isReq && input.headers));
    var ctx = {
      id: id, kind: 'fetch',
      url: isReq ? input.url : s(input),
      method: s(init.method || (isReq ? input.method : 'GET') || 'GET'),
      headers: headersToObj(isReq && !init.headers ? input.headers : init.headers),
      body: textOf(init.body),
      block: false, mock: null
    };
    if (isReq && init.body == null) {
      try { ctx.body = await input.clone().text(); } catch(e){}
    }
    var url0 = ctx.url;
    var plan = runRequest(ctx);
    send({t:'req', id:id, kind:'fetch', method:ctx.method, url:ctx.url,
          body:s(ctx.body).slice(0,20000), mut:plan.acts.join('、'),
          rh:reqHdr(ctx.headers),
          from: plan.urlChanged ? url0 : ''});

    if (plan.blocked) {
      send({t:'res', id:id, status:0, ok:false, ms:0, err:'脚本拦截', mut:'拦截'});
      throw new TypeError('Failed to fetch (被抓包脚本拦截)');
    }
    if (plan.mock) {
      var mst = Number(plan.mock.status || 200);
      var mbody = plan.mock.body == null ? '' : s(plan.mock.body);
      var mh = plan.mock.headers || {'content-type':'application/json'};
      send({t:'res', id:id, status:mst, ok:mst<400, ms:Date.now()-t0,
            ct:mh['content-type']||'', body:mbody.slice(0,200000),
            sh:hdr(mh), mut:'假返回'});
      var noBody = (mst===204||mst===205||mst===304);
      return new Response(noBody ? null : mbody, {status:mst, headers:mh});
    }

    var changed = plan.urlChanged || plan.methodChanged ||
                  plan.headersChanged || plan.bodyChanged;
    var res;
    try {
      if (!changed) {
        res = await of.apply(this, arguments);
      } else if (isReq) {
        res = await of(new Request(ctx.url, {
          method: ctx.method, headers: ctx.headers,
          body: (ctx.method==='GET'||ctx.method==='HEAD') ? undefined : ctx.body,
          credentials: input.credentials, mode: input.mode, cache: input.cache,
          redirect: input.redirect, referrer: input.referrer, integrity: input.integrity
        }));
      } else {
        var fin = {};
        for (var k in init) fin[k] = init[k];
        fin.method = ctx.method;
        if (plan.headersChanged || hadHeaders) fin.headers = ctx.headers;
        if (plan.bodyChanged) fin.body = ctx.body;
        res = await of(ctx.url, fin);
      }
    } catch(e) {
      // 浏览器原生 fetch 失败：最常见是跨域 CORS / 网络层 / 证书策略。
      // 这里降级到 Dart 侧原生 HTTP 再试一次，能绕过浏览器 CORS 拿到公开接口。
      // 代价是不再带当前页面的 Cookie；需要登录态时仍应先把浏览器开到目标站。
      try {
        var nres = await nativeFetch(ctx);
        var nbody = nres.body == null ? '' : s(nres.body);
        var nh = nres.headers || {};
        send({t:'res', id:id, status:Number(nres.status), ok:nres.status>=200&&nres.status<400,
              ms:Date.now()-t0, ct:(nh['content-type']||nh['Content-Type']||''),
              body:nbody.slice(0,200000), rh:reqHdr(ctx.headers), sh:fmtHdrs(nh), mut:'native-fallback'});
        return new Response(nbody, {status: Number(nres.status), headers: new Headers(nh)});
      } catch(e2) {
        send({t:'res', id:id, status:0, ok:false, ms:Date.now()-t0, err:String(e), mut:'native-fallback-failed'});
        throw e;
      }
    }

    // clone 后再读，别把页面自己的 body 消费掉。
    var text = '';
    try { text = await res.clone().text(); } catch(e){}
    var hdrObj = {};
    try { res.headers.forEach(function(v,k){ hdrObj[k] = v; }); } catch(e){}
    var rctx = {
      id: id, kind: 'fetch', url: res.url || ctx.url, method: ctx.method,
      status: res.status, headers: hdrObj, body: text,
      request: {url: ctx.url, method: ctx.method, headers: ctx.headers, body: ctx.body}
    };
    var out = runResponse(rctx);
    var mut = plan.acts.concat(out.acts).join('、');
    send({t:'res', id:id, status:rctx.status, ok:rctx.status>=200&&rctx.status<400,
          ms:Date.now()-t0,
          ct:rctx.headers['content-type'] ||
             ((res.headers && res.headers.get('content-type')) || ''),
          body:s(rctx.body).slice(0,200000),
          rh:reqHdr(ctx.headers), sh:hdr(rctx.headers), mut:mut});
    if (out.acts.length === 0) return res;
    var newHeaders;
    try { newHeaders = new Headers(rctx.headers); }
    catch(e){ newHeaders = new Headers(); }
    var empty = (rctx.status===204||rctx.status===205||rctx.status===304);
    var fake = new Response(empty ? null : rctx.body,
      {status: Number(rctx.status), statusText: res.statusText, headers: newHeaders});
    try { Object.defineProperty(fake, 'url', {value: res.url}); } catch(e){}
    return fake;
  };

  // -------------------------------------------------------------- XHR
  var OX = window.XMLHttpRequest;
  function PX(){
    var x = new OX();
    var id = ++seq, t0 = 0;
    var ctx = {id:id, kind:'xhr', url:'', method:'GET', headers:{}, body:'',
               block:false, mock:null};
    var plan = {acts:[], blocked:false, mock:null};
    var reported = false;

    // 抢在页面之前挂监听：页面通常先 new 再赋 onreadystatechange，
    // 构造函数里注册就一定排在它前面，这样我们能先把返回体改掉。
    x.addEventListener('readystatechange', function(){
      if (x.readyState !== 4 || reported) return;
      reported = true;
      var raw = '', typed = false;
      try {
        if (x.responseType && x.responseType !== '' && x.responseType !== 'text') {
          typed = true; raw = '[' + x.responseType + ']';
        } else { raw = x.responseText || ''; }
      } catch(e){}
      var hdrObj = {};
      try { hdrObj = rawHeadersToObj(x.getAllResponseHeaders() || ''); } catch(e){}
      var rctx = {
        id:id, kind:'xhr', url:ctx.url, method:ctx.method,
        status:x.status, headers:hdrObj, body:raw,
        request:{url:ctx.url, method:ctx.method, headers:ctx.headers, body:ctx.body}
      };
      var out = runResponse(rctx);
      var mut = plan.acts.concat(out.acts).join('、');
      if (out.acts.length > 0 && typed) {
        mut += '（responseType=' + x.responseType + '，改不了）';
      }
      if (out.acts.length > 0 && !typed) {
        try {
          if (out.bodyChanged) {
            Object.defineProperty(x, 'responseText',
              {get:function(){ return rctx.body; }, configurable:true});
            Object.defineProperty(x, 'response',
              {get:function(){ return rctx.body; }, configurable:true});
          }
          if (out.statusChanged) {
            Object.defineProperty(x, 'status',
              {get:function(){ return Number(rctx.status); }, configurable:true});
          }
          if (out.headersChanged) {
            Object.defineProperty(x, 'getAllResponseHeaders', {value:function(){
              var a=[]; for (var k in rctx.headers) a.push(k + ': ' + rctx.headers[k]);
              return a.join('\r\n');
            }, configurable:true});
            Object.defineProperty(x, 'getResponseHeader', {value:function(name){
              var low = s(name).toLowerCase();
              for (var k in rctx.headers) {
                if (k.toLowerCase() === low) return rctx.headers[k];
              }
              return null;
            }, configurable:true});
          }
        } catch(e){}
      }
      send({t:'res', id:id, status:rctx.status,
            ok:rctx.status>=200&&rctx.status<400, ms:Date.now()-t0,
            ct:rctx.headers['content-type']||'',
            body:s(rctx.body).slice(0,200000),
            rh:reqHdr(ctx.headers), sh:hdr(rctx.headers), mut:mut});
    });

    var open = x.open;
    x.open = function(method, url){
      ctx.method = s(method || 'GET'); ctx.url = s(url);
      return open.apply(x, arguments);
    };
    // 请求头先记着不真设：脚本要能删掉某个头，只能等 send 时一次性落。
    var setHeader = x.setRequestHeader;
    x.setRequestHeader = function(k, v){ ctx.headers[s(k)] = s(v); return undefined; };

    var sendf = x.send;
    x.send = function(b){
      t0 = Date.now();
      ctx.body = textOf(b);
      var url0 = ctx.url;
      plan = runRequest(ctx);
      send({t:'req', id:id, kind:'xhr', method:ctx.method, url:ctx.url,
            body:s(ctx.body).slice(0,20000), mut:plan.acts.join('、'),
            rh:reqHdr(ctx.headers),
            from: plan.urlChanged ? url0 : ''});

      if (plan.blocked) {
        reported = true;
        send({t:'res', id:id, status:0, ok:false, ms:0, err:'脚本拦截', mut:'拦截'});
        setTimeout(function(){
          try {
            x.dispatchEvent(new ProgressEvent('error'));
            x.dispatchEvent(new ProgressEvent('loadend'));
          } catch(e){}
        }, 0);
        return undefined;
      }
      if (plan.mock) {
        reported = true;
        var mst = Number(plan.mock.status || 200);
        var mbody = plan.mock.body == null ? '' : s(plan.mock.body);
        send({t:'res', id:id, status:mst, ok:mst<400, ms:Date.now()-t0,
              body:mbody.slice(0,200000), rh:reqHdr(ctx.headers), mut:'假返回'});
        setTimeout(function(){
          try {
            Object.defineProperty(x, 'readyState', {get:function(){ return 4; }, configurable:true});
            Object.defineProperty(x, 'status', {get:function(){ return mst; }, configurable:true});
            Object.defineProperty(x, 'responseText', {get:function(){ return mbody; }, configurable:true});
            Object.defineProperty(x, 'response', {get:function(){ return mbody; }, configurable:true});
            x.dispatchEvent(new Event('readystatechange'));
            x.dispatchEvent(new ProgressEvent('load'));
            x.dispatchEvent(new ProgressEvent('loadend'));
          } catch(e){}
        }, 0);
        return undefined;
      }

      // 地址/方法改了要重新 open，否则改的是个没人用的字段。
      if (plan.urlChanged || plan.methodChanged) {
        try { open.call(x, ctx.method, ctx.url, true); } catch(e){}
      }
      for (var k in ctx.headers) {
        try { setHeader.call(x, k, ctx.headers[k]); } catch(e){}
      }
      return sendf.call(x, plan.bodyChanged ? ctx.body : b);
    };
    return x;
  }
  PX.prototype = OX.prototype;
  ['UNSENT','OPENED','HEADERS_RECEIVED','LOADING','DONE'].forEach(function(k, i){
    try { PX[k] = i; } catch(e){}
  });
  window.XMLHttpRequest = PX;

  ['log','warn','error'].forEach(function(lv){
    var o = console[lv];
    console[lv] = function(){
      try { send({t:'log', level:lv, text:Array.prototype.map.call(arguments, String).join(' ').slice(0,4000)}); } catch(e){}
      return o.apply(console, arguments);
    };
  });
  window.onerror = function(msg, src, line){ send({t:'log', level:'error', text: msg + ' @' + line}); };
})();
''';

/// 新建脚本时给的骨架：能直接跑，注释里写清能改什么。
const String interceptScriptTemplate =
    r'''// 请求钩子：改地址 / 方法 / 请求头 / 请求体，或整包拦掉、直接假返回。
function onRequest(req) {
  // if (req.url.indexOf('/api/order') >= 0 && req.method === 'POST') {
  //   req.body = req.body.replace('"amount":1', '"amount":99');
  //   req.headers['X-Debug'] = '1';
  //   QL.log('改了下单包', req.body);
  // }
  // req.block = true;                              // 整包拦掉
  // req.mock = {status: 200, body: '{"ok":true}'};  // 不发出去，直接假返回
}

// 响应钩子：改状态码 / 返回头 / 返回体。res.request 是对应的请求。
function onResponse(res) {
  // if (res.url.indexOf('/api/me') >= 0) {
  //   var data = JSON.parse(res.body);
  //   data.vip = true;
  //   res.body = JSON.stringify(data);
  // }
}
''';

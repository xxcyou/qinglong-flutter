# 主题开发者技能包 —— DSHTheme 组件特效 / 主题 ZIP 接口

> 这份文档是主题包开发的**完整接口手册**。AI 做主题、组件特效、发光、布偶、
> 落叶、气泡、角标、桌面宠物等需求前先读它；只改 App 内置样式的做法已废弃。
> 主题包内图片路径统一用 `window.DSH_PACKAGE_ROOT` 拼接，不要写死包 id。

## 1. 主题包结构

主题一律是 ZIP 包，除 `README.md`、`controller.js` 外其他全是目录：

```
controller.js                 # 总控，声明 theme 配置与资源路由
html/index.html               # 背景 HTML（可选）
html/menu.html                # 配置菜单（可选）
css/、js/                     # 背景样式/脚本
image/elements/               # 叶子、布偶、角标等图片
xml/                          # 声明式组件/特效 XML（可选）
audio/                        # 音效（可选）
config.json                   # 菜单保存的实时配置（导出时一起带走）
```

`controller.js` 是入口，App 读取其中的 `const theme = {...}` 和
`themeResources`。`controller.js` 必须存在，纯色主题也写在里面。

### 1.1 controller.js 示例

```javascript
// 总控：主题基础配置 + 资源路由
const theme = {
  id: 'sakura_night',
  name: '夜樱',
  brightness: 'dark',                       // dark / light
  backgroundImage: '',                      // 背景图 guest 路径，空 = 纯配色
  colors: {
    primary: '#66BB6A',
    primaryContainer: '#1C4030',
    onPrimaryContainer: '#B9F6CA',
    accent: '#4FC3F7',
    background: '#0F1115',
    surface: '#1A1D24',
    surfaceLow: '#14171C',
    surfaceHigh: '#22262F',
    surfaceHighest: '#2A2F38',
    onSurface: '#E8EAED',
    onSurfaceVariant: '#9AA0A6',
    outline: '#8A9096',
    outlineVariant: '#3A4048',
    border: '#FFFFFF',
    shadow: '#000000',
    success: '#4CAF50',
    warning: '#FFB300',
    error: '#E57373',
    errorContainer: '#5F1111',
    onErrorContainer: '#F8BBD0'
  },
  effects: {                                // 数值型视觉效果
    glassBlur: 26,
    glassBorderOpacity: 0.16,
    glassShadowY: 6,
    glassShadowOpacity: 0.20,
    glassRadius: 22,
    cardRadius: 16,
    floatingDepth: 4,
    animationDurationMs: 250,
    animatedGradient: 0
  },
  typography: {                             // 全局字体排版
    family: '/workspace/.ql_themes/packages/<id>/fonts/custom.ttf',
    size: '16',
    weight: '400',
    color: '#E8EAED',
    opacity: '1',
    strikethrough: 'false',
    gold: 'false'
  },
  // 主题包自带组件风格：所有 panel/card/bubble 的默认装饰。
  // 最新发光配置都写在这里，App 设置里已不再提供内外发光按钮。
  componentStyle: {
    glowColor: '#00D4FF',
    glowRadius: 16,
    glowOpacity: 0.8,
    glowSharpness: 0.35,
    glowShape: 'auto',
    innerGlow: {
      color: '#7DF9FF',
      radius: 8,
      opacity: 0.5,
      sharpness: 0.5,
      side: 'all'
    }
  }
};

const themeResources = {
  components: {
    background: {
      script: 'js/background.js',
      css: 'css/background.css',
      html: 'html/index.html',
      xml: 'xml/animations/background.xml'
    }
  },
  images: 'image/elements',
  audio: 'audio'
};

export default themeResources;
```

### 1.2 controller.js 字段

- `id`：主题 id。
- `name`：显示名。
- `brightness`：`dark` 或 `light`。
- `backgroundImage`：背景图 guest 路径，空 = 纯配色。
- `colors`：配色表，见上面键名。
- `effects`：数值效果表，见上面键名。
- `typography`：全局字体排版，键为 `family/size/weight/color/opacity/strikethrough/gold`。
- `componentStyle`：主题包自带组件风格，字段和 `DSHTheme.styleComponent` 的 `style` 完全一致，见第 4 节。
- 也兼容把 `componentStyle` 写成 `styles` 或 `glow`，但推荐 `componentStyle`。

## 2. 主题包能力与层级

- 主题包的 html/css/js 运行在全屏 WebView 背景层。
- `window.DSHTheme.*` 可以在 Flutter 组件**上层**绘制图片、文字、气泡、动画。
- `GlassPanel`/`GlassCard`/AI 气泡会自动上报锚点，JS 可用
  `DSHTheme.queryComponents` 查到组件真实屏幕坐标。
- `effect` 是前景浮层，永远盖在组件上面；默认不挡点击。
- `styleComponent` 是**真改组件自身装饰**（边框、渐变、发光、圆角、阴影、
  纹理、液体玻璃），不是覆盖层。
- 目前没有“组件后方”图层；组件背景/内部装饰优先用 `styleComponent`，
  不要用 `effect` 假装背景。

## 3. DSHTheme.effect：前景特效

```javascript
const PKG = window.DSH_PACKAGE_ROOT;

DSHTheme.effect({
  id: 'petal_1',
  imagePath: PKG + '/image/elements/petal.png', // 包内相对路径也可以
  x: 120, y: 300, width: 40, height: 40,
  color: '#FF9EC4',
  animation: 'float',
  opacity: 0.9,
  rotation: -12,
  scale: 1,
  durationMs: 1800,
  fit: 'contain'
});

// 高性能批量更新：同一帧里更新很多粒子/布偶时用它，避免 60fps 消息洪水。
DSHTheme.effectBatch([
  { id: 'petal_1', imagePath: PKG + '/image/elements/petal.png', x: 10, y: 20, width: 32, height: 32, animation: 'float' },
  { id: 'petal_2', imagePath: PKG + '/image/elements/petal.png', x: 40, y: 60, width: 28, height: 28, animation: 'float' }
]);

DSHTheme.remove('petal_1');
DSHTheme.clear();
```

### 3.1 effect 字段表

| 字段 | 说明 |
|---|---|
| `id` | 必填。唯一 id，同 id 覆盖更新。 |
| `imagePath` | 包内图片路径，支持相对路径；推荐 `window.DSH_PACKAGE_ROOT + '/image/elements/x.png'`。 |
| `icon` | 内置图标：`sparkle/star/heart/flower/paw/fire/bolt/smile/ghost/magic`。 |
| `text` | 文字/气泡内容。 |
| `x/y/width/height` | 屏幕逻辑坐标和大小，默认 `0/0/80/80`。 |
| `color` | 主色，默认 `#FF9EC4`。 |
| `animation` | `none/float/bounce/spin/fade/pulse/shake/wiggle/blink/slide`，默认 `none`。 |
| `fit` | `contain/fill/cover`，默认 `contain`。 |
| `interactive` | `true` 时该特效可点击/长按；默认 `false` 不挡控件。 |
| `fontSize` | 文字大小，默认 `14`。 |
| `speechTail` | 是否画气泡尾巴，默认 `false`。 |
| `opacity` | 整体透明度 0~1，默认 `1`。 |
| `rotation` | 静态旋转角度（度），默认 `0`；会叠加在 `spin/wiggle` 动态角度上。 |
| `scale` | 整体缩放，默认 `1`。 |
| `durationMs` | 一个动画循环时长（毫秒），默认 `1800`。 |
| `textBackgroundColor` | 文字/气泡背景色。 |
| `textBorderColor` | 文字/气泡描边色。 |
| `textBorderWidth` | 气泡描边宽度，默认 `1.2`。 |
| `textRadius` | 气泡圆角，默认 `12`。 |
| `textPadding` | 气泡内边距，默认 `8`。 |
| `paint` | 不依赖图片，直接用 Canvas 画组件重绘效果，见 3.2。 |

### 3.2 paint 组件重绘

```javascript
DSHTheme.effect({
  id: 'glow',
  x: 100, y: 200, width: 600, height: 180,
  paint: { type: 'glow', colors: ['#00D4FF'], opacity: 0.8, borderWidth: 3, radius: 16, cornerRadius: 20 }
});
```

| paint 字段 | 说明 |
|---|---|
| `type` | `solid/gradient/radialGradient/glow/stroke/shadow/ellipse/ring/line/dashed`，默认 `solid`。 |
| `colors` | 颜色数组；多数类型用第一个颜色，渐变用全部。 |
| `opacity` | 0~1，默认 `1`。 |
| `borderWidth` | 描边/发光宽度，默认 `2`，范围 0.5~20。 |
| `radius` | `glow`/`shadow` 的模糊半径；`radialGradient` 的半径比例（0~1.2）。 |
| `cornerRadius` | 圆角半径，默认 `16`。 |
| `angle` | 渐变/线条角度（度），默认 `0`。 |
| `dashWidth` | `dashed` 虚线每段长度，默认 `6`。 |
| `dashGap` | `dashed` 虚线间隔，默认 `4`。 |

### 3.3 查询组件锚点

```javascript
DSHTheme.queryComponents({
  page: 'default',       // 可省略或传 '*' 查全部
  type: 'panel',         // panel / card / bubble，可省略
  callback: function (list) {
    // list: [{ page, type, index, x, y, w, h }]
  }
});
```

### 3.4 手势互动

默认特效不拦截点击；只有 `interactive: true` 的特效才会收到手势：

```javascript
DSHTheme.onEffect('tap', function (e) {
  // e.id = 被点中的特效 id
});
DSHTheme.onEffect('longPress', function (e) {
  // 长按
});

DSHTheme.effect({
  id: 'puppet',
  imagePath: PKG + '/image/elements/puppet.png',
  x: 20, y: 40, width: 80, height: 80,
  animation: 'bounce',
  interactive: true
});
```

## 4. DSHTheme.styleComponent：真改组件

```javascript
DSHTheme.styleComponent({
  page: 'default',     // 省略或 '*' = 所有页面
  type: 'panel',       // panel / card / bubble；省略或 '*' = 所有类型
  index: 0,            // 省略 = 所有同类型组件
  style: {
    // 填充/边框
    color: '#1A1D24',
    colors: ['#1a1a2e', '#3a2d0a'], // 渐变，配 angle
    angle: 135,
    borderColor: '#D4AF37',
    borderWidth: 3,
    borderOpacity: 0.9,
    fillOpacity: 0.7,
    radius: 22,
    // 外发光（最新）
    glowColor: '#D4AF37',
    glowRadius: 14,
    glowOpacity: 0.8,
    glowSharpness: 0.4,   // 0=浓雾扩散，1=边缘锐利
    glowShape: 'auto',    // auto / roundRect / oval / rect
    // 投影
    shadowColor: '#000000',
    shadowOpacity: 0.35,
    shadowBlur: 12,
    shadowOffsetY: 6,
    // 内发光
    innerGlow: {
      color: '#7DF9FF',
      opacity: 0.5,
      radius: 8,
      sharpness: 0.6,
      side: 'all'         // all/top/bottom/left/right
    },
    // 内阴影
    innerShadow: {
      color: '#000000',
      opacity: 0.4,
      blur: 10,
      offsetX: 0,
      offsetY: 2,
      side: 'bottom'
    },
    // 整体玻璃/纹理
    opacity: 1,
    blur: 26,
    backgroundImage: PKG + '/image/textures/wood.png',
    backgroundImageFit: 'cover',      // cover/fill/contain
    backgroundImageOpacity: 0.35,
    // 液体玻璃（最大程度逼近苹果 Liquid Glass）
    liquid: {
      blur: 30,
      refraction: 0.4,
      specular: 0.65,
      lightX: 0.72,
      lightY: 0.14,
      ripple: 0.35,
      tint: '#88CCFF',
      tintOpacity: 0.32,
      caustic: 0.25,
      thickness: 0.5,
      edgeHighlight: true,
      innerShadow: true,
      animated: false
    }
  }
});

// 只撤销 JS 规则；主题包 controller.js 里的 componentStyle 全局默认仍会保留。
DSHTheme.removeComponentStyle({ page: 'default', type: 'panel', index: 0 });
```

### 4.1 style 字段表

| 字段 | 说明 |
|---|---|
| `color` | 纯色填充，覆盖渐变/默认玻璃底色。 |
| `colors` | 渐变颜色数组；不是 `gradientColors`。 |
| `angle` | 渐变角度，默认 `135`。 |
| `borderColor/borderWidth/borderOpacity` | 边框颜色/宽度/透明度。 |
| `glowColor/glowRadius/glowOpacity` | 外发光颜色/半径/强度。 |
| `glowSharpness` | 外发光锐化 0~1，默认 0（柔和扩散）。 |
| `glowShape` | `auto/roundRect`=圆角矩形；`oval`=椭圆/圆形；`rect`=直角矩形。 |
| `fillOpacity` | 填充透明度。 |
| `radius` | 组件圆角。 |
| `shadowColor/shadowOpacity/shadowBlur/shadowOffsetY` | 投影。 |
| `innerGlow` | 内发光对象：`color`/`opacity`/`radius`/`sharpness`/`side`（all/top/bottom/left/right）。也兼容顶层 `innerGlowColor` 等写法。 |
| `innerShadow` | 内阴影对象：`color`/`opacity`/`blur`/`offsetX`/`offsetY`/`side`（all/top/bottom/left/right）。 |
| `opacity` | 组件整体透明度 0~1。 |
| `blur` | 玻璃/液体玻璃模糊强度。 |
| `backgroundImage` | 背景纹理图路径；别名 `texture`/`bgImage`。 |
| `backgroundImageFit` | `cover/fill/contain`；别名 `textureFit`。 |
| `backgroundImageOpacity` | 纹理透明度。 |
| `liquid` | 液体玻璃参数对象，见下。 |

`liquid` 字段：

| 字段 | 说明 |
|---|---|
| `blur` | 背景模糊；不传沿用 `style.blur`/组件默认。 |
| `refraction` | 折射/边缘光晕强度，默认 `0.4`。 |
| `specular` | 镜面高光强度 0~1，默认 `0.65`。 |
| `lightX/lightY` | 光源位置比例 0~1，默认 `0.72/0.14`。 |
| `ripple` | 高光/波纹流动幅度，默认 `0.35`。 |
| `tint/tintOpacity` | 玻璃染色和透明度，默认无染色/`0.32`。 |
| `caustic` | 焦散光斑强度 0~1，默认 `0.25`。 |
| `thickness` | 玻璃厚度感 0~2，默认 `0.5`。 |
| `edgeHighlight` | 是否画边缘高光，默认 `true`。 |
| `innerShadow` | 是否画内阴影，默认 `true`。 |
| `animated` | `false`（默认）= 静态液态玻璃，不闪烁；`true` = 高光/波纹持续流动。 |

### 4.2 匹配规则

- `page/type/index` 都可省略；省略、`'*'` 都表示“全部匹配”。
- 规则会存下来，ListView 里以后才 build 出来的组件也能生效。
- 优先级（越靠前越精确，后写的精确规则覆盖通配规则）：
  `page+type+index` > 任意 index > 任意 type > 全通配。
- 组件类型：`panel`（GlassPanel）、`card`（GlassCard）、`bubble`（AI 气泡）。

## 5. controller.js 里的 componentStyle

`componentStyle` 是**主题级全局默认样式**，字段和上面的 `style` 完全一致，
会作为最底层应用到所有 `panel/card/bubble`。JS 的 `DSHTheme.styleComponent`
规则可以按 `page/type/index` 覆盖它。

```javascript
const theme = {
  // ...
  componentStyle: {
    glowColor: '#00D4FF',
    glowOpacity: 0.8,
    glowRadius: 16,
    glowSharpness: 0.35,
    innerGlow: { color: '#7DF9FF', radius: 8, opacity: 0.5, side: 'all' }
  }
};
```

- 外发光 = `glow*`；内发光 = `innerGlow`。
- 最新版本 App 设置里没有内外发光按钮，发光只由主题包 ZIP 的
  `componentStyle`（或主题 JS 的 `DSHTheme.styleComponent`）控制。
- 没有显式配置时，不会覆盖组件默认发光。

## 6. XML 声明式特效

`xml/` 目录下所有 `.xml` 会在主题激活时解析。支持 `<effect>` 或
`<component>` 标签，属性名和 `DSHTheme.effect` 字段一致；`id` 可省略。

```xml
<effects>
  <effect id="petal-1"
          imagePath="image/elements/petal.png"
          x="120" y="80" width="48" height="48"
          color="#FFB3BA"
          animation="float" durationMs="2400"
          opacity="0.9" />
  <effect id="badge-1"
          icon="sparkle"
          x="720" y="56" width="32" height="32"
          color="#FFD700" />
</effects>
```

适合启动即挂载的静态装饰：角标、固定光点、常驻布偶。需要每帧逻辑
（跟随、弹跳、互动）的仍用 JS 调 `DSHTheme.effect`。

## 7. DSHThemeMenu：主题配置菜单

- 主题包可带 `html/menu.html`；App 设置页长按该主题会弹出悬浮配置窗。
- 菜单里用 `window.DSHThemeMenu`：
  - `DSHThemeMenu.getConfig(cb)`：读取主题包 `config.json`。
  - `DSHThemeMenu.saveConfig(cfg)`：实时保存到 `config.json`。
  - `DSHThemeMenu.close()`：关闭菜单。
  - `DSHThemeMenu.effect(e)` / `DSHThemeMenu.remove(id)` / `DSHThemeMenu.clear()` /
    `DSHThemeMenu.styleComponent(options)` / `DSHThemeMenu.queryComponents(opts)`：
    和背景 `DSHTheme` 一样实时生效；菜单桥没有 `effectBatch`/`removeComponentStyle`，
    批量更新或撤销规则请直接用背景 `DSHTheme`。
- **不要做保存按钮**：控件变化时同时 `saveConfig` + `effect/styleComponent`。
- `config.json` 会随 `theme_manage export_zip` 一起导出，所以“菜单里配好
  再导出”就是带初始配置的主题包。

## 8. 标准实现套路

### 8.1 落叶/花瓣飘在组件上
- 图片放 `image/elements/leaf.png`；
- `effect` 设 `animation:'float'`；
- 用 `setInterval`/`requestAnimationFrame` 更新 x/y，多层随机大小/延迟；
- 粒子建议 ≤6 个、更新 ≤10fps，批量更新用 `effectBatch`。

### 8.2 边缘发光 / 四角 / 角标
- 优先 `styleComponent` 真改组件：`glowColor/glowRadius/glowOpacity/glowSharpness/glowShape`。
- 内发光用 `innerGlow`，圆形组件用 `glowShape:'oval'`。
- 角标用 `effect` 把图标/图片贴在组件左上/右上/左下/右下，`index` 区分同类型组件。

### 8.3 2D/3D 布偶 / 互动 / 气泡
- 布偶图放 `image/elements/puppet.png`；
- `effect` 挂组件上方，`animation:'bounce'`；
- 需要点击时设 `interactive:true` 并 `onEffect('tap'/'longPress')` 更新动作/气泡；
- 也可在主题 JS 里自己监听 `document` 坐标命中。

### 8.4 组件背景内布偶弹跳
- `queryComponents` 拿组件矩形；
- JS 每帧把布偶位置限制在矩形内弹跳；
- 用 `effectBatch` 或合并更新，避免每帧多次 `effect` 消息。

### 8.5 指定某个组件
- `queryComponents` 返回 `index`；
- `styleComponent({page,type,index,style})` 精确改第几个；
- 不传 `index` 或传 `type:'*'` 应用到全部匹配组件。

## 9. 性能与约束

- 图片路径必须用主题包内 guest 路径或相对路径，不要写死包 id。
- `effect` 默认不挡点击；需要手势才设 `interactive:true`。
- 没有 behind 图层；组件背景用 `styleComponent`。
- 面向手机性能：不要 three.js/WebGL/大音频/高帧率 canvas/每帧
  `queryComponents`；优先静态图或轻量 CSS；粒子 ≤6、更新 ≤10fps、
  不自动播放音频；高频更新优先 `effectBatch`。
- App 只负责渲染 DSHTheme 请求的效果，不内置固定组件特效。
- 高级效果必须完整写进主题包，不能依赖 App 内置样式。

## 10. 制作/安装流程

1. `theme_manage create` 生成基础包。
2. shell 写 `html/index.html`、`js/*.js`、`css/*.css`、`image/elements/*`、
   `xml/*.xml`，在 `controller.js` 里声明资源和 `componentStyle`。
3. 需要菜单配置就加 `html/menu.html`，用 `DSHThemeMenu` 实时保存 `config.json`。
4. `theme_manage export_zip` 导出 ZIP。
5. `theme_manage import_zip` 导入安装并应用。

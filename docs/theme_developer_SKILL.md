# 主题开发者技能包 —— DSHTheme 万能组件特效接口

## 用途
让 APP 内的 AI 生成/安装真正能实现高级组件效果的主题包：
- 落叶飘在组件上
- 组件半浮动
- 樱花树背景
- 组件边框发光 / 局部边缘发光 / 四角发光
- 元素图标挂边角
- 2D/3D 布偶挂件、动作、互动、说话气泡
- 组件背景内布偶撞来撞去
- 所有布局特效由主题包自己实现，App 只提供渲染覆盖层接口

## App 开放的能力
1. 主题包 html/css/js 运行在全屏 WebView 背景层。
2. JS 调用 `window.DSHTheme.*` 可以在 Flutter 组件**上层**绘制图片/文字/气泡/动画，不阻塞点击。
3. `GlassPanel`/`GlassCard` 自动上报组件坐标，JS 可用 `DSHTheme.queryComponents` 查询。

## DSHTheme API

> 主题包内图片路径不要写死包 id，统一用 `window.DSH_PACKAGE_ROOT` 拼接：
> `window.DSH_PACKAGE_ROOT + '/image/elements/petal.png'`。
> ZIP 导入后包目录会变成 `pkgxxx`，写死旧 id 会读不到图。

```javascript
DSHTheme.effect({
  id: 'petal_1',
  imagePath: '/workspace/.ql_themes/packages/xxx/image/elements/petal.png',
  x: 120, y: 300, width: 40, height: 40,
  animation: 'float' // none | float | bounce | spin
});

DSHTheme.effect({
  id: 'bubble_1',
  text: '主人好~',
  x: 300, y: 500, width: 200, height: 60,
  color: '#FF9EC4', fontSize: 14, speechTail: true
});

DSHTheme.queryComponents({
  type: 'panel', // panel 或 card，可省略查全部
  callback: function(list) {
    // [{page, type, index, x, y, w, h}]
  }
});

DSHTheme.remove('petal_1');
DSHTheme.clear();
```

## effect 字段
| 字段 | 说明 |
|---|---|
| id | 唯一 id，同 id 覆盖更新 |
| imagePath | 主题包内图片 guest 路径 |
| icon | 内置图标名：sparkle/star/heart/flower/paw/fire/bolt/smile/ghost/magic |
| text | 文字/气泡内容 |
| x/y/width/height | 屏幕逻辑坐标与大小 |
| color | 颜色 |
| animation | none/float/bounce/spin |
| kind | image / border / corner；border=原生边缘发光，corner=四角镀金 |
| fit | contain/fill/cover，图片填充方式 |
| fontSize | 文字大小 |
| speechTail | 是否显示气泡尾巴 |

## 标准实现套路

### 落叶飘在组件上
- 把落叶图放 `image/elements/leaf.png`
- JS 每 20ms 更新 `DSHTheme.effect` 的 x/y，用 `animation:'float'` 抖动
- 多层叶子、错开时间、大小随机

### 边缘发光 / 角标
- 用 `queryComponents` 拿到组件矩形
- 发光：主题 css 可在背景层画 `filter: drop-shadow`；角标：用 DSHTheme 把图标/图片放到组件左上/右上/左下/右下
- `index` 区分同类型组件

### 布偶 / 互动 / 气泡
- 布偶图放 `image/elements/puppet.png`
- 用 `DSHTheme.effect` 放在组件上方，`animation:'bounce'`
- JS 监听 touch/click，更新 `text` 气泡或换动作图

### 组件背景内布偶弹跳
- `queryComponents` 得到组件矩形
- JS 每帧更新布偶位置，限制在矩形内弹跳，DSHTheme 实时更新

## 主题包制作/安装流程
1. `theme_manage create` 生成基础包
2. shell 写 html/js/css/image，controller.js 声明资源
3. `theme_manage export_zip` 导出 ZIP
4. `theme_manage import_zip` 导入安装应用

## 约束
- App 不做固定组件特效，所有高级效果必须写进主题包。
- 特效覆盖层默认不挡点击，不要用 DSHTheme 做需要原生输入拦截的效果。
- 图片路径必须用主题包内 guest 路径。

# 功率监测 · Power Monitor

整机耗电曲线和充电记录，按状态统计，可导出

*Power draw and charging over time, by state, exportable*

容悦 E5（OpenWrt）信息屏应用。当前版本 **v1.1**，应用 ID `powermon`。

## 截图

![功率曲线](screenshots/power-chart.jpg)

LuCI：状态 → 功率监测。整机功率曲线，下方色条标出屏幕亮、热点开、省电、插电的时段，绿色底为插电时段。

![各状态平均功率](screenshots/power-by-state.jpg)

按状态统计平均功率、电流和满电可用时长（不含插电时段）。

## 安装

1. 下载 [`releases/powermon-v1.1.tar.gz`](releases/powermon-v1.1.tar.gz)。
2. 在信息屏的「应用管理」中安装（LuCI：服务 → 信息屏应用 → 应用管理）。
3. 安装后文件位于设备上的 `/etc/e5-infoscreen/plugins/powermon/`。

## 设置

加粗为默认值。

- 采样间隔（Sample interval）：5 秒；**10 秒**；30 秒；1 分钟

## 源码

`powermon/` 是当前版本安装包解压后的内容：

- [`backend.uc`](powermon/backend.uc)
- [`index.html`](powermon/index.html)
- [`luci/acl.json`](powermon/luci/acl.json)
- [`luci/index.js`](powermon/luci/index.js)
- [`luci/menu.json`](powermon/luci/menu.json)
- [`manifest.json`](powermon/manifest.json)
- [`powermon.init`](powermon/powermon.init)
- [`service.sh`](powermon/service.sh)

## 版本

- [v1.1](releases/powermon-v1.1.tar.gz)（当前）
- [v1.0](releases/powermon-v1.0.tar.gz)

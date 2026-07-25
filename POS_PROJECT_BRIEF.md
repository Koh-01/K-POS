# 餐厅 POS 系统 — 项目需求与架构文档

> 本文档整合了完整功能需求与技术架构决策，作为开发上下文交给 Claude Code 使用。
> 单店运营，Android App（Admin + Cashier 共用）+ Admin 网站（电脑端报表/管理）。

---

## 1. 技术架构总览

```
Android App (Flutter)
├── 登录后按角色显示界面：Admin / Cashier
├── 本地 SQLite（离线优先，缓存商品/桌位/待同步订单）
└── 调用 FastAPI 后端

FastAPI 后端（部署在 Ubuntu Server, Docker, 复用现有 Cloudflare Tunnel）
├── 唯一业务逻辑层（税率/服务费/促销计算/权限判断）
├── 同时提供：
│   ├── JSON API（给 Flutter App 用）
│   └── Jinja2 + Bootstrap 网页（给 Admin 网站用，同一个项目内出）
├── 自动生成 Swagger API 文档
└── 连接 MariaDB

MariaDB（单一数据源，所有正式数据）
└── 每天定时备份 → Google Drive
    └── 每月 1 日自动生成月报告，存入 Google Drive
```

### 三层数据架构

```
POS App
  ↓
SQLite（本地，离线优先）
  ↓ 同步
Ubuntu Server
  ↓
FastAPI（业务逻辑）
  ↓
MariaDB（主数据库）
  ↓ 每天 12:00 自动备份
Google Drive（云端备份）
```

| 层级 | 用途 |
|---|---|
| 本地 SQLite | 没网时继续开单、收款、查看商品/桌位 |
| Server + MariaDB | 所有正式数据、报表、商品、用户、订单的唯一来源 |
| Google Drive | 每日自动备份、每月自动报告 |

### 关键架构决策记录（决策原因）

1. **App 和网站不直连数据库，都通过 FastAPI 调用** —— 避免业务逻辑（税率计算、promotion 逻辑）在两端各写一份导致后期跑偏。
2. **后端选 FastAPI 而非 Flask** —— 需要同一套 API 同时给 App 和网站用，FastAPI 自动生成 Swagger 文档，且内置 Pydantic 数据校验，对价格/税率这类金额字段的正确性更有保障。
3. **网站前端选服务端渲染（Jinja2 + Bootstrap）而非 React** —— 网站只做管理后台和报表导出，优先求快速可用，不追求复杂交互体验。
4. **DuitNow QR 只是付款方式标签**，不接入任何收单机构 API——收银员选择付款方式后系统只记录标签，QR 码本身是店家自己账户的静态图片，顾客自行扫码转账，收银员人工核实到账。**不涉及交易回调、对账、手续费。**
5. **蓝牙打印机是国产热敏打印机（Bluetooth SPP 协议）** —— 该协议**只支持 Android**，不支持 iOS（iOS 蓝牙打印需 MFi 认证设备）。本项目只做 Android App，无影响。Flutter 端建议用 `blue_thermal_printer` 或 `print_bluetooth_thermal`。
6. **单店运营** —— 云同步层不需要做多门店数据隔离。

---

## 2. 功能需求详情

### 2.1 用户管理（User Management）

- 登录（Username / Password），**登录一次即可，不需要每次重新登录**（含 Cashier 设备）
- 角色权限管理：
  - **Admin**：可查看报告 —— 每个物品的销量，按年/月/星期/天统计
  - **Cashier**：日常点餐收银操作
- 修改密码
- 用户资料管理
- 登录日志
- **Cashier 在没网状态下也能正常使用**（依赖本地 SQLite）
- 注册流程：先注册 Admin 账号 → Admin 在系统内添加 Cashier 账号
- Cashier 设备登录一次即可，不需要每天重新登录

### 2.2 产品管理（Product Management）

> Admin 和 Cashier 都可以管理，**同时管理时需要及时同步**（双写场景，注意冲突处理）

- 新增 / 编辑 / 删除商品
- 商品分类管理（Category），例如：汤底、肉类、饮料、配菜
- 商品图片上传
- 商品价格管理
- 商品状态：售卖中 / 停售

### 2.3 点餐系统（Order Management）

- 创建订单 —— **跟着桌位保存订单**
- 修改订单 —— 编辑内容 / 更换桌位
- **Combine 订单** —— 例如一个顾客开了两个座位，需要合并成一张订单
- 删除订单
- 订单备注
- 用餐方式：堂食（Dine In）/ 外带（Take Away）

### 2.4 收银系统（Payment Module）

- 现金支付
- DuitNow QR（仅作付款方式标签，见架构决策 #4）
- 可查看已经 proceed payment 的订单
- **删除 / 编辑已 proceed payment 的订单**：
  - 删除场景：收银员输入错物品，需整单重打
  - 编辑场景：小部分失误，可直接编辑后重新打印小票
  - ⚠️ 需设计审计追踪机制（记录修改前内容、修改人、修改时间），避免财务记录被随意篡改而无法追溯
- 自动计算：
  - SST 和 Service Charge —— **用户可自行决定开启/关闭**
  - Subtotal
  - Service Charge
  - SST
  - Discount —— **只有实际有折扣时才显示在小票上**
  - Grand Total

### 2.5 Promotion 管理

> Admin 和 Cashier 都可以自行新增 / 删除 / 编辑 promotion 的力度和类型

- Discount %
- Buy 1 Free 1
- Happy Hour
- Promo Code

### 2.6 报表系统（Reporting）

> 支持 Export to CSV

- 每日 / 每周 / 每月销售额
- 热销商品
- **Cash In / Cash Out**：记录每一笔进账和支出
- 每月自动生成报告：营业额 / Cash In / Cash Out
- **每年生成报告供报税用** —— 需要包含：
  - 全年每一天的销售额记录
  - 全年 Cash In / Cash Out 记录
  - 全年每一个物品的销售额记录

**Admin Dashboard：**
- Today's Revenue
- Orders Today
- Top Selling Product
- Active Tables

### 2.7 Receipt 打印

- Bluetooth Printer（国产热敏打印机，SPP 协议）
  - 可设置小票厚度
  - 测试连接（Test Connection）
- Export to PDF

**小票内容（用户可自行编辑）：**
- 店名
- 订单编号
- 商品列表
- 税务资料
- 总金额
- QR Code

### 2.8 云端同步（Cloud Sync）

- 自动保存到 Google Drive
- 每月第一天自动生成月报告，保存至 Google Drive
- 云端同步：**每天 12:00 自动备份一次**
- 数据备份
- 多设备同步
- Offline Mode
- 自动恢复

### 2.9 系统设置（Settings）

- 店铺资料
- 税率设置
- 打印机设置
- 支付方式设置
- 主题切换（Dark / Light）

### 2.10 数据保留策略

- 数据库每两年清理上一年的数据
- Google Drive 备份空间满时，系统自行删除旧备份，**并发出通知**

---

## 3. Admin 网站（电脑端）

- 与 App 功能完全对齐（App 能做的，网站都能做）
- 仅 Admin 角色可登录
- 主要使用场景：报账时用电脑 Export 资料（CSV / PDF）
- 默认有网络，**不需要离线模式**
- 技术：FastAPI 项目内的 Jinja2 + Bootstrap 页面，直接调用同一套业务逻辑层

---

## 4. 开发阶段规划

### Phase 0 — 地基
- 数据库 schema 设计（MariaDB + SQLite 两套结构一致，便于同步）
- 同步策略设计（`updated_at` / `synced_at` / `device_id` 等字段，冲突处理规则）
- FastAPI 项目骨架 + 连接现有 Ubuntu Server
- Flutter 项目骨架

### Phase 1 — 可营业的 MVP
- 登录（Admin / Cashier，离线免每日登录）
- 商品管理（CRUD + 分类）
- 点餐（建单 / 编辑 / 堂食外带 / 桌位 / 合并订单）
- 收银（现金 / DuitNow QR 标签，Subtotal / SST / Service Charge / Discount 自动计算）
- 小票打印（蓝牙热敏打印机适配）

### Phase 2 — 运营增强
- 已支付订单的编辑 / 删除（带审计记录）
- Promotion 管理
- 日常报表（日 / 周 / 月销售额、热销商品）
- Admin Dashboard

### Phase 3 — 云端与报税
- Google Drive 自动备份（每日 12:00）
- 月报告 / 年报告自动生成
- Cash In / Cash Out 记录功能

### Phase 4 — 打磨
- 系统设置（店铺资料 / 税率 / 打印机 / 主题）
- 登录日志
- Offline 自动恢复
- 数据保留策略（两年清理、Google Drive 满载通知）

---

## 5. 待设计 / 待确认事项

- [ ] 数据库 schema 详细设计（核心表：users, products, categories, tables, orders, order_items, payments, promotions, cash_records）
- [ ] 软删除字段规则（删除商品/订单是否真删，还是标记状态保留审计能力）
- [ ] 已支付订单编辑/删除的审计追踪具体实现方式
- [ ] SQLite ↔ MariaDB 同步冲突处理规则（双端同时编辑商品时如何判定谁的数据生效）
- [ ] 蓝牙打印机具体型号对应的 ESC/POS 指令兼容性测试

---

## 6. 技术栈总结

| 层 | 技术 |
|---|---|
| 移动端 | Flutter（Android，Admin + Cashier 共用 App） |
| 本地存储 | SQLite |
| 后端 API | FastAPI（Python） |
| 网站前端 | Jinja2 + Bootstrap（与 FastAPI 同项目） |
| 主数据库 | MariaDB |
| 服务器 | Ubuntu Server 24.04 LTS（已有，Docker 部署） |
| 远程访问 | Cloudflare Tunnel（已有配置） |
| 云端备份 | Google Drive |
| 打印 | 国产热敏打印机，Bluetooth SPP 协议（Android only） |
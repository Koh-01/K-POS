# POS 系统 — 开发进度交接文档

> 给 Claude Code 接手用。请先读完本文档 + 同目录的 `POS_PROJECT_BRIEF.md`（完整需求与架构），再继续开发。

---

## 项目背景（一句话）

单店餐厅 POS 系统：Flutter Android App（Admin + Cashier 共用）+ FastAPI 后端（同时出 JSON API 给 App、出 Jinja2+Bootstrap 网页给 Admin 网站）+ MariaDB 主库 + App 本地 SQLite 离线缓存。完整需求见 `POS_PROJECT_BRIEF.md`。

---

## 已完成并验证通过的部分（Backend 认证模块）

环境：
- 开发机：Windows，Python 3.14，VS Code
- 后端目录：`backend/`，已建 venv，已 `pip install fastapi uvicorn sqlalchemy pymysql python-jose passlib python-multipart jinja2 bcrypt`
- 数据库：MariaDB 11 跑在 Ubuntu Server 上（Docker 容器名 `pos-mariadb`），通过 Tailscale IP `100.81.67.19:3306` 连接
- 启动命令：`uvicorn main:app --reload`

已验证通过的功能：
1. ✅ FastAPI 启动正常，Swagger `/docs` 可访问
2. ✅ 连接远程 MariaDB 成功（`/db-check` 返回 connected）
3. ✅ `users` 表已建好
4. ✅ 密码 bcrypt 加密（注意：**已绕过 passlib**，直接用 `bcrypt` 库，因为 passlib 与新版 bcrypt 不兼容，报 `module 'bcrypt' has no attribute '__about__'`）
5. ✅ 注册 admin、登录均返回 200，登录已返回 JWT token

---

## 现有文件清单（backend/）

- `main.py` — FastAPI 入口，含 `/`、`/db-check`、`/setup/first-admin`、`/users`、`/login`、`/me`
- `database.py` — SQLAlchemy engine + session，DATABASE_URL 连 `100.81.67.19`
- `models.py` — User 表 model（id, username, password_hash, role, full_name, is_active, created_at, updated_at）
- `auth.py` — bcrypt 密码加密（hash_password / verify_password），**直接用 bcrypt 库，未用 passlib**
- `token_utils.py` — JWT 生成/解码，`ACCESS_TOKEN_EXPIRE_DAYS = 30`（对应"登录一次不用每天登录"需求）
- `dependencies.py` — `get_current_user` + `require_admin` 权限依赖
- `schemas.py` — UserCreate / UserResponse / LoginRequest
- `create_tables.py` — 建表脚本

---

## 当前卡点（需要先解决）

`dependencies.py` 里用的是 `OAuth2PasswordBearer(tokenUrl="login")`，导致 Swagger 的 Authorize 弹窗显示成 OAuth2 username/password 登录表单，无法直接粘贴 token（因为我们的 `/login` 收 JSON body，不是标准 OAuth2 表单格式）。

**建议修复方向**：把 `OAuth2PasswordBearer` 换成 `HTTPBearer`，让 Authorize 弹窗变成纯 token 输入框。相应地 `get_current_user` 取 token 的方式要改为 `token.credentials`（HTTPBearer 返回对象而非字符串）。

请帮我做这个修复，并验证完整认证流程：注册 admin → 登录拿 token → Authorize → `/me` 返回身份 → `/users` 能让 admin 新增 cashier、非 admin 被 403 拒绝。

---

## 接下来的开发计划（按优先级）

### 立即要做（认证模块收尾）
- [ ] 修复 Swagger Authorize 体验（HTTPBearer）
- [ ] 验证 admin 新增 cashier 流程、权限拦截（cashier 不能调 admin 接口）
- [ ] `SECRET_KEY` 移到环境变量（目前硬编码在 token_utils.py，上线前必须换）

### Phase 1 剩余（今天目标：跑通 MVP 骨架）
- [ ] 商品管理 API：categories + products 表，CRUD，商品状态（售卖中/停售），分类（汤底/肉类/饮料/配菜）
- [ ] 商品图片上传（参考用户过往项目用 Pillow 压缩的经验）
- [ ] 点餐 API：tables（桌位）+ orders + order_items 表，建单/改单/堂食外带/换桌位/合并订单
- [ ] 收银 API：payments 表，现金/DuitNow QR 标签，自动算 subtotal/SST/service charge/discount/grand total（SST 和 service charge 可开关）
- [ ] Flutter App 骨架：登录界面 → 角色判断 → 进入 Admin/Cashier 不同界面

### 后续 Phase（见 POS_PROJECT_BRIEF.md）
- Phase 2：已支付订单编辑/删除（带审计追踪）、Promotion、报表、Dashboard
- Phase 3：Google Drive 备份、月报/年报、Cash In/Out
- Phase 4：系统设置、登录日志、离线自动恢复、数据保留策略

---

## 重要技术注意事项

1. **bcrypt 不要用 passlib** — 直接用 bcrypt 库，passlib 已与新版 bcrypt 不兼容。
2. **数据库连接走 Tailscale IP** `100.81.67.19`，不要暴露 3306 到公网。
3. **金额计算逻辑只能写在后端**（FastAPI 业务逻辑层），App 和网站都调 API，禁止两端各写一份税率/折扣计算，避免数字算不一致。
4. **软删除 + 审计** — 商品、订单（尤其已支付订单的编辑/删除）需要软删除字段和审计追踪，schema 设计时要预留，不要真删数据。这是财务记录完整性的底线要求。
5. **SQLite ↔ MariaDB 同步** — App 离线优先，需要 `updated_at`/`synced_at`/`device_id` 之类字段处理同步与冲突，schema 两套结构要一致。
6. **Python 3.14 很新**，个别包若报兼容问题，可考虑降级到 3.12。
7. 开发机是 Windows，PowerShell 激活 venv 用 `venv\Scripts\activate`；曾遇执行策略限制，需 `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`。
8. MariaDB 客户端命令在容器里是 `mariadb` 不是 `mysql`。
9. **数据库密码目前是弱密码 `200410`**，仅开发用，上线前必须换强密码并移到环境变量。

---

## 给 Claude Code 的第一条指令建议

```
读一下 HANDOFF_TO_CLAUDE_CODE.md 和 POS_PROJECT_BRIEF.md。
先帮我修复 dependencies.py 的 Swagger Authorize 问题（换成 HTTPBearer），
验证完整认证流程，然后我们继续做商品管理 API。
```
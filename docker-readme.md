# 🐳 Docker部署指南

## 📋 快速开始

### 一键部署
```bash
# 克隆或下载代码后，执行：
./deploy.sh
```

### 手动部署
```bash
# 1. 构建镜像
docker-compose build

# 2. 启动服务
docker-compose up -d

# 3. 查看状态
docker-compose ps

# 4. 查看日志
docker-compose logs -f
```

## 🏗️ 服务架构

### 服务组件
- **golf-dashboard**: Flask应用容器 (端口5000)
- **nginx**: 反向代理容器 (端口80)
- **watchtower**: 自动更新容器

### 目录结构
```
hitdate/
├── Dockerfile              # Flask应用镜像构建
├── docker-compose.yml      # 服务编排配置
├── nginx.conf             # Nginx配置文件
├── deploy.sh              # 一键部署脚本
├── stop.sh               # 停止服务脚本
├── .dockerignore          # Docker忽略文件
└── docker-readme.md       # Docker部署说明
```

## 🔧 配置选项

### 端口映射
编辑 `docker-compose.yml`:
```yaml
ports:
  - "8080:80"    # 改为8080端口
  - "5000:5000"  # 直接访问Flask
```

### 数据持久化
数据存储在以下目录：
- `./data/` - SQLite数据库
- `./logs/` - 应用日志

### 环境变量
```yaml
environment:
  - FLASK_ENV=production
  - FLASK_DEBUG=0
```

## 📊 常用命令

### 服务管理
```bash
# 启动服务
docker-compose up -d

# 停止服务
docker-compose down

# 重启服务
docker-compose restart

# 查看日志
docker-compose logs -f golf-dashboard
docker-compose logs -f nginx

# 进入容器
docker-compose exec golf-dashboard bash
docker-compose exec nginx sh
```

### 数据管理
```bash
# 备份数据库
docker-compose exec golf-dashboard sqlite3 /app/data/golf_stats.db ".backup /app/data/backup.db"

# 查看数据库
docker-compose exec golf-dashboard sqlite3 /app/data/golf_stats.db ".tables"

# 导出数据
docker-compose exec golf-dashboard sqlite3 /app/data/golf_stats.db ".dump" > backup.sql
```

### 更新和清理
```bash
# 更新镜像
docker-compose pull
docker-compose up -d

# 清理无用镜像
docker image prune -f

# 完全清理
docker-compose down --volumes --remove-orphans
docker system prune -f
```

## 🌐 访问地址

部署完成后，可以通过以下地址访问：
- **看板**: http://localhost
- **API**: http://localhost/api/golf_stats
- **数据**: http://localhost/api/dashboard_data

## 🔍 故障排查

### 检查服务状态
```bash
docker-compose ps
```

### 查看详细日志
```bash
# 查看所有服务日志
docker-compose logs

# 查看特定服务日志
docker-compose logs golf-dashboard

# 实时查看日志
docker-compose logs -f
```

### 网络问题
```bash
# 检查容器网络
docker network ls
docker network inspect hitdate_default

# 测试容器间通信
docker-compose exec nginx curl http://golf-dashboard:5000/api/dashboard_data
```

### 数据库问题
```bash
# 检查数据库文件
docker-compose exec golf-dashboard ls -la /app/data/

# 数据库完整性检查
docker-compose exec golf-dashboard sqlite3 /app/data/golf_stats.db "PRAGMA integrity_check;"
```

## 🚀 生产环境部署

### 使用环境变量文件
创建 `.env` 文件：
```bash
# 端口配置
HTTP_PORT=80
FLASK_PORT=5000

# 环境配置
FLASK_ENV=production
FLASK_DEBUG=0

# 数据卷配置
DATA_PATH=./data
LOGS_PATH=./logs
```

### 使用外部数据库
修改 `docker-compose.yml`:
```yaml
services:
  golf-dashboard:
    environment:
      - DATABASE_URL=postgresql://user:pass@postgres:5432/golf_stats
  postgres:
    image: postgres:13
    environment:
      POSTGRES_DB: golf_stats
      POSTGRES_USER: user
      POSTGRES_PASSWORD: pass
```

## 🔄 自动更新

Watchtower会自动检查并更新容器镜像：
- 检查间隔：1小时
- 自动清理旧镜像
- 零停机更新

如需禁用自动更新：
```bash
# 编辑docker-compose.yml，注释掉watchtower服务
docker-compose up -d
```
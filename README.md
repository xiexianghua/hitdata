# 高尔夫击球数据看板系统

## 🎯 功能概述

这个系统包含两部分：
1. **后端API** (`app.py`) - 接收和存储高尔夫击球数据
2. **前端看板** (`templates/dashboard.html`) - 实时显示各设备每日击球数据

## 🚀 快速启动

### 1. 启动服务器
```bash
./start_server.sh
```

服务器将在 `http://localhost:5000` 启动

### 2. 配置bash脚本
在你的bash脚本中修改以下配置：

```bash
# 修改为你的服务器地址
SERVER_URL="http://localhost:5000/api/golf_stats"
```

### 3. 访问看板
打开浏览器访问：
- **看板页面**: http://localhost:5000
- **API测试**: http://localhost:5000/api/dashboard_data

## 📊 看板功能

- **实时数据**: 自动每30秒刷新
- **设备卡片**: 显示每个设备的DNA、总击球数、今日击球数、活跃天数
- **趋势图表**: 使用Chart.js显示每日击球数变化趋势
- **响应式设计**: 适配手机、平板、电脑

## 🔧 API说明

### 接收数据
**POST** `/api/golf_stats`

**请求格式**:
```json
{
  "device_id": "4c30890501506046365aa689",
  "daily_data": {
    "2025-07-28": 15,
    "2025-07-27": 23
  }
}
```

### 获取看板数据
**GET** `/api/dashboard_data`

**响应格式**:
```json
[
  {
    "device_id": "4c30890501506046365aa689",
    "created_at": "2025-07-28 03:32:32",
    "daily_stats": [
      {"date": "2025-07-28", "hit_count": 15},
      {"date": "2025-07-27", "hit_count": 23}
    ]
  }
]
```

## 📁 文件结构

```
hitdate/
├── app.py              # Flask后端应用
├── start_server.sh     # 启动脚本
├── requirements.txt    # Python依赖
├── golf_stats.db       # SQLite数据库（自动生成）
├── templates/
│   └── dashboard.html  # 前端看板页面
└── README.md          # 使用说明
```

## 🔍 调试技巧

1. **测试API**: 
   ```bash
   curl -X POST http://localhost:5000/api/golf_stats \
     -H "Content-Type: application/json" \
     -d '{"device_id":"test","daily_data":{"2025-07-28":10}}'
   ```

2. **查看数据**:
   ```bash
   curl http://localhost:5000/api/dashboard_data | python3 -m json.tool
   ```

3. **数据库查询**:
   ```bash
   sqlite3 golf_stats.db "SELECT * FROM daily_stats ORDER BY date DESC;"
   ```
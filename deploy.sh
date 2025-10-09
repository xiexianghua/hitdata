#!/bin/bash

# 高尔夫数据看板Docker部署脚本

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 高尔夫数据看板Docker部署脚本${NC}"
echo "========================================"

# 检查Docker是否安装
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}❌ Docker未安装，请先安装Docker${NC}"
    echo "安装命令:"
    echo "  curl -fsSL https://get.docker.com | bash"
    exit 1
fi

# 检查Docker Compose是否安装
if ! command -v docker-compose >/dev/null 2>&1; then
    echo -e "${RED}❌ Docker Compose未安装，请先安装${NC}"
    echo "安装命令:"
    echo "  sudo apt-get install docker-compose"
    exit 1
fi

# 创建必要的目录
echo -e "${BLUE}📁 创建必要目录...${NC}"
mkdir -p data logs

# 检查配置文件是否存在
if [[ ! -f "Dockerfile" ]]; then
    echo -e "${RED}❌ Dockerfile不存在${NC}"
    exit 1
fi

if [[ ! -f "docker-compose.yml" ]]; then
    echo -e "${RED}❌ docker-compose.yml不存在${NC}"
    exit 1
fi

# 构建镜像
echo -e "${BLUE}🏗️  构建Docker镜像...${NC}"
docker-compose build --no-cache

# 启动服务
echo -e "${BLUE}🚀 启动服务...${NC}"
docker-compose up -d

# 等待服务启动
echo -e "${BLUE}⏳ 等待服务启动...${NC}"
sleep 10

# 检查服务状态
if docker-compose ps | grep -q "Up"; then
    echo -e "${GREEN}✅ 服务启动成功！${NC}"
    echo ""
    echo -e "${GREEN}🌐 访问地址:${NC}"
    echo "  看板页面: http://localhost"
    echo "  API端点: http://localhost/api/golf_stats"
    echo ""
    echo -e "${GREEN}📊 管理命令:${NC}"
    echo "  查看日志: docker-compose logs -f"
    echo "  停止服务: docker-compose down"
    echo "  重启服务: docker-compose restart"
    echo "  更新镜像: docker-compose pull && docker-compose up -d"
    echo ""
    echo -e "${YELLOW}⚠️  在bash脚本中设置:${NC}"
    echo "  SERVER_URL=\"http://localhost/api/golf_stats\""
else
    echo -e "${RED}❌ 服务启动失败${NC}"
    echo "查看日志:"
    docker-compose logs
    exit 1
fi
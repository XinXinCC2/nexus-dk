#!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
BUILD_DIR="/root/nexus-docker"

function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker 未安装，正在安装..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        systemctl enable docker
        systemctl start docker
    fi
}

function prepare_build_files() {
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    bash \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | bash
RUN ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"
LOG_FILE="/root/nexus.log"

mkdir -p "$(dirname "$PROVER_ID_FILE")"
echo "$NODE_ID" > "$PROVER_ID_FILE"
echo "使用的 node-id: $NODE_ID"

[ -n "$NEXUS_LOG" ] && LOG_FILE="$NEXUS_LOG"
[ -n "$SCREEN_NAME" ] || SCREEN_NAME="nexus"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "nexus-network 未安装"
    exit 1
fi

screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true

echo "启动 nexus-network..."
screen -dmS "$SCREEN_NAME" bash -c "nexus-network start --node-id $NODE_ID &>> $LOG_FILE"

sleep 3

if screen -list | grep -q "$SCREEN_NAME"; then
    echo "实例 [$SCREEN_NAME] 已启动，日志文件：$LOG_FILE"
else
    echo "启动失败：$SCREEN_NAME"
    cat "$LOG_FILE"
    exit 1
fi

tail -f "$LOG_FILE"
EOF
}

function build_image() {
    cd "$BUILD_DIR"
    docker build -t "$IMAGE_NAME" .
}

function start_instances() {
    read -rp "请输入要创建的实例数量: " INSTANCE_COUNT

    if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || [ "$INSTANCE_COUNT" -lt 1 ]; then
        echo "无效数量。请输入正整数。"
        exit 1
    fi

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        read -rp "请输入第 $i 个实例的 node-id: " NODE_ID

        CONTAINER_NAME="nexus-node-$i"
        LOG_FILE="/root/nexus-$i.log"
        SCREEN_NAME="nexus-$i"

        echo "正在启动实例：$CONTAINER_NAME"

        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

        docker run -d \
            --name "$CONTAINER_NAME" \
            -e NODE_ID="$NODE_ID" \
            -e NEXUS_LOG="$LOG_FILE" \
            -e SCREEN_NAME="$SCREEN_NAME" \
            -v "$LOG_FILE":"$LOG_FILE" \
            "$IMAGE_NAME"

        echo "✅ 启动成功：$CONTAINER_NAME"
    done
}

function stop_all_instances() {
    echo "🛑 正在停止所有 nexus-node-* 容器..."
    docker ps -a --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        echo "停止 $name"
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    echo "✅ 所有实例已停止。"
}

function restart_instance() {
    read -rp "请输入要重启的实例编号（例如 3 表示 nexus-node-3）: " idx
    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="/root/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    echo "正在重启实例 $CONTAINER_NAME..."

    NODE_ID=$(docker inspect -f '{{ index .Config.Env }}' "$CONTAINER_NAME" 2>/dev/null | grep NODE_ID= | cut -d= -f2)

    if [ -z "$NODE_ID" ]; then
        echo "❌ 找不到实例或 node-id，可能未运行或未创建。"
        return
    fi

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        "$IMAGE_NAME"

    echo "✅ 已重启：$CONTAINER_NAME"
}

function show_running_ids() {
    echo "🔍 正在查询所有运行中的 Nexus 实例及 node-id..."
    docker ps --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        ID=$(docker exec "$name" cat /root/.nexus/node-id 2>/dev/null)
        echo "实例：$name     node-id: $ID"
    done
}

function show_menu() {
    while true; do
        echo ""
        echo "=========== Nexus 节点管理 ==========="
        echo "1. 构建并启动新实例"
        echo "2. 停止所有实例"
        echo "3. 重启指定实例"
        echo "4. 查看运行中的实例及 ID"
        echo "5. 退出"
        echo "======================================"
        read -rp "请选择操作 (1-5): " choice
        case "$choice" in
            1) check_docker; prepare_build_files; build_image; start_instances ;;
            2) stop_all_instances ;;
            3) restart_instance ;;
            4) show_running_ids ;;
            5) echo "已退出"; exit 0 ;;
            *) echo "无效选择";;
        esac
    done
}

### 脚本入口
show_menu



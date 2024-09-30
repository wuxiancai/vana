#!/bin/bash

# DLP Validator 安装路径
DLP_PATH="/root/vana-dlp-chatgpt"

# 检查是否以root用户运行脚本
if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要以root用户权限运行。"
    echo "请尝试使用 'sudo -i' 命令切换到root用户，然后再次运行此脚本。"
    exit 1
fi

# 在Ubuntu 22.04容器中安装并运行DLP Validator节点
function install_dlp_node() {
    echo "在 Docker 容器中安装 DLP Validator 节点..."
    docker run -it --name dlp-validator-container -e PATH="/root/.local/bin:$PATH" -w /root ubuntu:22.04 /bin/bash -c '
    # 更新并安装必要的依赖
    apt update && apt upgrade -y
    apt install -y curl wget jq make gcc nano git software-properties-common
    

    # 安装 Python 3.11 和 Poetry
    add-apt-repository ppa:deadsnakes/ppa -y
    apt update
    apt install -y python3.11 python3.11-venv python3.11-dev python3-pip
    curl -sSL https://install.python-poetry.org | python3 -


    echo "验证 Poetry 安装..."
    poetry --version

    # 安装 Node.js 和 npm
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
    apt-get install -y npm

    # 安装 PM2
    npm install pm2@latest -g

    # 克隆 Vana DLP ChatGPT 仓库并安装依赖
    git clone https://github.com/vana-com/vana-dlp-chatgpt.git
    cd vana-dlp-chatgpt
    cp .env.example .env
    python3.11 -m venv myenv
    source myenv/bin/activate
    poetry install
    pip install vana

    # 创建钱包
    vanacli wallet create --wallet.name default --wallet.hotkey default

    # 导出私钥
    vanacli wallet export_private_key
    vanacli wallet export_private_key

    # 确认备份
    read -p "是否已经备份好私钥,并且对应冷钱包已经领水? (y/n) " backup_confirmed
    if [ "$backup_confirmed" != "y" ]; then
        echo "请先备份好助记词，对应冷钱包领水, 然后再继续执行脚本。"
        exit 1
    fi

    # 生成加密密钥
    ./keygen.sh

    # 将公钥写入 .env 文件
    PUBLIC_KEY_FILE="/root/vana-dlp-chatgpt/public_key_base64.asc"
    ENV_FILE="/root/vana-dlp-chatgpt/.env"

    # 检查公钥文件是否存在
    if [ ! -f "$PUBLIC_KEY_FILE" ]; then
        echo "公钥文件不存在: $PUBLIC_KEY_FILE"
        exit 1
    fi

    # 读取公钥内容
    PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")

    # 将公钥写入 .env 文件
    echo "PRIVATE_FILE_ENCRYPTION_PUBLIC_KEY_BASE64=\"$PUBLIC_KEY\"" >> "$ENV_FILE"

    echo "公钥已成功写入到 .env 文件中。"

    # 部署智能合约
    cd $HOME
    git clone https://github.com/Josephtran102/vana-dlp-smart-contracts
    cd vana-dlp-smart-contracts
    npm install -g yarn
    yarn install
    cp .env.example .env
    nano .env  # 手动编辑 .env 文件
    npx hardhat deploy --network moksha --tags DLPDeploy

    # 注册验证器
    cd $HOME
    cd vana-dlp-chatgpt

    # 创建 .env 文件
    echo "创建 .env 文件..."
    read -p "请输入 DLP 合约地址: " DLP_CONTRACT
    read -p "请输入 DLP Token 合约地址: " DLP_TOKEN_CONTRACT
    read -p "请输入 OpenAI API Key: " OPENAI_API_KEY

    cat <<EOF > /root/vana-dlp-chatgpt/.env
# The network to use, currently Vana Moksha testnet
OD_CHAIN_NETWORK=moksha
OD_CHAIN_NETWORK_ENDPOINT=https://rpc.moksha.vana.org

# Optional: OpenAI API key for additional data quality check
OPENAI_API_KEY="$OPENAI_API_KEY"

# Optional: Your own DLP smart contract address once deployed to the network, useful for local testing
DLP_MOKSHA_CONTRACT="$DLP_CONTRACT"

# Optional: Your own DLP token contract address once deployed to the network, useful for local testing
DLP_TOKEN_MOKSHA_CONTRACT="$DLP_TOKEN_CONTRACT"
EOF
    ./vanacli dlp register_validator --stake_amount 10
    read -p "请输入您的 Hotkey 钱包地址: " HOTKEY_ADDRESS
    ./vanacli dlp approve_validator --validator_address="$HOTKEY_ADDRESS"

    # 创建 PM2 配置文件
    echo "创建 PM2 配置文件..."
    cat <<EOF > /root/vana-dlp-chatgpt/ecosystem.config.js
module.exports = {
  apps: [
    {
      name: 'vana-validator',
      script: '$HOME/.local/bin/poetry',
      args: 'run python -m chatgpt.nodes.validator',
      cwd: '/root/vana-dlp-chatgpt',
      interpreter: 'python3.11', 
      env: {
        PATH: '/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/root/vana-dlp-chatgpt/myenv/bin',
        PYTHONPATH: '/root/vana-dlp-chatgpt',
        OD_CHAIN_NETWORK: 'moksha',
        OD_CHAIN_NETWORK_ENDPOINT: 'https://rpc.moksha.vana.org',
        OPENAI_API_KEY: '$OPENAI_API_KEY',
        DLP_MOKSHA_CONTRACT: '$DLP_CONTRACT',
        DLP_TOKEN_MOKSHA_CONTRACT: '$DLP_TOKEN_CONTRACT',
        PRIVATE_FILE_ENCRYPTION_PUBLIC_KEY_BASE64: '$PUBLIC_KEY'
      },
      restart_delay: 10000, 
      max_restarts: 10, 
      autorestart: true,
      watch: false,
    },
  ],
};
EOF

    # 使用 PM2 启动 DLP Validator 节点
    echo "使用 PM2 启动 DLP Validator 节点..."
    pm2 start /root/vana-dlp-chatgpt/ecosystem.config.js

    echo "设置 PM2 开机自启..."
    pm2 save

    tail -f /dev/null
    '
    echo "DLP Validator 容器已启动并在后台运行。"
    echo "要进入容器，请使用命令: docker exec -it dlp-validator-container /bin/bash"
}

# 查看节点日志
function check_node() {
    docker exec -it dlp-validator-container pm2 logs vana-validator
}

# 卸载节点
function uninstall_node() {
    echo "卸载 DLP Validator 节点..."
    docker stop dlp-validator-container
    docker rm dlp-validator-container
    echo "DLP Validator 节点已删除。"
}

# 主菜单
function main_menu() {
    clear
    echo "脚本以及教程由推特用户大赌哥 @y95277777 编写，免费开源，请勿相信收费"
    echo "========================= VANA DLP Validator 节点安装 ======================================="
    echo "节点社区 Telegram 群组:https://t.me/niuwuriji"
    echo "节点社区 Telegram 频道:https://t.me/niuwuriji"
    echo "节点社区 Discord 社群:https://discord.gg/GbMV5EcNWF"    
    echo "请选择要执行的操作:"
    echo "1. 安装 DLP Validator 节点"
    echo "2. 查看节点日志"
    echo "3. 删除节点"
    read -p "请输入选项（1-3）: " OPTION
    case $OPTION in
    1) install_dlp_node ;;
    2) check_node ;;
    3) uninstall_node ;;
    *) echo "无效选项。" ;;
    esac
}

# 显示主菜单
main_menu

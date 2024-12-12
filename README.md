# 自动编译 Nginx for Xray_bash_onekey

## 简介
本项目旨在为 [hello-yunshu/Xray_bash_onekey](https://github.com/hello-yunshu/Xray_bash_onekey) 提供一个优化的 Nginx 版本，它使用最新的 OpenSSL、Jemalloc 和 Nginx 源码进行编译。通过集成这些组件，我们确保了更高的性能和安全性，特别适合需要快速部署和高并发处理的场景。

## 特点
- **最新版本**：始终使用最新的稳定版 Nginx、OpenSSL 和 Jemalloc 进行编译。
- **性能优化**：采用 Jemalloc 作为内存分配器以提升内存管理效率。
- **安全增强**：利用最新的 OpenSSL 库来保证数据传输的安全性。
- **一键安装**：简化了安装流程，使得配置和服务启动更加简便。

## 安装指南

### 前提条件
在开始之前，请确保您的系统满足以下要求：
- 支持的操作系统：Linux（已测试于 Ubuntu, CentOS）
- 已安装基础构建工具和依赖项

### 安装步骤
1. 克隆此仓库至本地：
    ```bash
    git clone https://github.com/hello-yunshu/Xray_bash_onekey_Nginx.git
    cd Xray_bash_onekey_Nginx
    ```

2. 安装必须的库文件：
   pcre、zlib

3. 赋予执行权限并运行：
    ```bash
    chmod +x nginx
    ./nginx
    ```

4. 配置 Nginx：
   根据您的需求修改 Nginx 配置文件（位于 `/usr/local/nginx/nginx.conf`）, 
   默认以 `nobody:nogroup` 用户运行

5. 启动或重启 Nginx 服务：
    ```bash
    sudo systemctl start nginx
    # 或者
    sudo systemctl restart nginx
    ```

## 注意事项
- 下载过程可能需要一定时间，具体取决于您的服务器的网络性能。
- 如果遇到任何问题或者有改进建议，请随时提交 [Issue](https://github.com/hello-yunshu/Xray_bash_onekey_Nginx/issues) 或者 Pull Request。

## 联系方式
如果您有任何疑问或建议，欢迎通过以下方式联系我们：
- GitHub Issues: [Issues](https://github.com/hello-yunshu/Xray_bash_onekey_Nginx/issues)

感谢您选择我们的项目！希望这个自动编译的 Nginx 能够为您的部署带来便利。

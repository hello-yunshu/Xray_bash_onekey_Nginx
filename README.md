# 自动编译全静态 Nginx for Xray_bash_onekey

## 简介

本仓库为 [hello-yunshu/Xray_bash_onekey](https://github.com/hello-yunshu/Xray_bash_onekey) 自动构建可直接分发的 Nginx 二进制包。构建目标是全静态链接 Nginx，并将 OpenSSL、Jemalloc、PCRE2、zlib 等依赖一并编入发布产物，减少目标服务器上的运行时依赖。

如果 CI 无法生成全静态二进制，发布流程会直接失败，不再把动态链接产物标记为全静态。

## 发布产物

每个 Release 默认包含：

- `xray-nginx-custom-x86.tar.gz`：x86_64 服务器使用。
- `xray-nginx-custom-arm.tar.gz`：aarch64/arm64 服务器使用。
- `release-manifest.json`：主项目消费的发布清单，包含架构、文件名、版本和 SHA256。
- `SHA256SUMS` 与单独的 `.sha256` 文件：用于校验下载文件。
- `build-static-report-*.txt`：记录 `file`、`ldd`、`objdump`、`nginx -V` 的静态链接验证结果。

## 手动安装

推荐优先通过主项目安装脚本使用本仓库产物。确需手动安装时，可以按当前系统架构从最新 Release 下载对应包：

```bash
arch="$(uname -m)"
case "$arch" in
  x86_64) asset_arch="x86" ;;
  aarch64|arm64) asset_arch="arm" ;;
  *) echo "unsupported architecture: $arch"; exit 1 ;;
esac

base_url="https://github.com/hello-yunshu/Xray_bash_onekey_Nginx/releases/latest/download"

curl -fLO "${base_url}/release-manifest.json"
filename="$(jq -r --arg arch "$asset_arch" '.assets[] | select(.arch == $arch) | .filename' release-manifest.json)"
sha256="$(jq -r --arg arch "$asset_arch" '.assets[] | select(.arch == $arch) | .sha256' release-manifest.json)"

curl -fLO "${base_url}/${filename}"
echo "${sha256}  ${filename}" | sha256sum -c -

sudo rm -rf /usr/local/nginx
sudo tar -xzf "${filename}" -C /usr/local
sudo /usr/local/nginx/sbin/nginx -t
```

## 与主项目的关系

`Xray_bash_onekey` 会根据 `release-manifest.json` 选择正确架构的包，并在存在 SHA256 时进行校验。旧 Release 如果没有 manifest，主项目会回退到历史文件名，避免已有版本无法安装。

## 构建说明

GitHub Actions 每 2 小时检查一次版本。只有 Nginx 或核心构建依赖版本变化时才会构建并发布；发布成功后才会更新 `.github/previous_versions.json`，避免定时检查产生无意义提交。

`.github/previous_versions.json` 只是本仓库判断“上次成功构建使用了哪些源码/依赖版本”的内部快照。主项目不会直接读取这个文件；主项目读取的是 `Xray_bash_onekey_api` 仓库里的 `xray_shell_versions.json`。API 仓库会根据本仓库最新 Release tag 更新 `nginx_build_online_version`，主项目再用这个版本号下载对应 Release。

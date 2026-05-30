#!/bin/bash
set -euo pipefail

REPO_DIR="/mnt/aur/custom/repo"
DB_NAME="aurcustomrepo.db.tar.gz"

# ---------- 工具函数 ----------
# 从包文件名中提取包名（利用 pkgver/pkgrel/arch 不含 '-' 的特性）
extract_pkgname() {
    local filename="$1"
    local name="${filename%.pkg.tar.*}"       # 去掉尾缀 .pkg.tar.zst / .pkg.tar.xz 等
    name="${name%-*}"                         # 去掉 arch
    name="${name%-*}"                         # 去掉 pkgrel
    name="${name%-*}"                         # 去掉 pkgver（包名自身可含 '-'）
    basename "$name"
}

# 修剪字符串尾部空白
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ---------- 处理每个目录 ----------
while IFS= read -r -d '' dir; do
    dir_display="${dir#./}"
    printf "\033[0;32m[INFO] 处理目录: %s\033[0m\n" "$dir_display"

    # 检查是否为 meta 包（忽略校验和错误）
    is_meta=false
    if [[ "$dir_display" == *meta* ]]; then
        is_meta=true
        printf "\033[0;33m[NOTE] 检测到 meta 包, 将忽略校验和错误\033[0m\n"
    fi

    if ! pushd "$dir" >/dev/null; then
        printf "\033[0;31m[ERROR] 无法进入目录: %s\033[0m\n" "$dir"
        continue
    fi

    # 1. 更新校验和
    if ! updpkgsums; then
        if [ "$is_meta" = false ]; then
            printf "\033[0;31m[ERROR] 更新校验和失败: %s\033[0m\n" "$dir"
            popd >/dev/null
            continue
        else
            printf "\033[0;33m[WARN] meta 包忽略校验和失败: %s\033[0m\n" "$dir"
        fi
    fi

    # 2. 生成 .SRCINFO（使用临时文件避免残留空文件）
    tmp_srcinfo=$(mktemp)
    if makepkg --printsrcinfo >"$tmp_srcinfo" 2>/dev/null; then
        mv "$tmp_srcinfo" .SRCINFO
    else
        rm -f "$tmp_srcinfo"
        printf "\033[0;31m[ERROR] 生成 .SRCINFO 失败: %s\033[0m\n" "$dir"
        popd >/dev/null
        continue
    fi

    # 3. 解析 .SRCINFO（支持分包子包的独立架构）
    unset pkgbase_name global_pkgver global_pkgrel global_epoch global_arch
    declare -a pkgnames=()
    declare -A pkg_arch=()          # 每个子包的 arch
    current_pkg=""                  # 当前正在解析的 pkgname 块

    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" == \#* ]] && continue

        # 提取键和值，并修剪值尾部空白
        key=$(echo "$line" | sed -n 's/^[[:space:]]*\([^[:space:]=]*\)[[:space:]]*=[[:space:]]*.*/\1/p')
        value=$(echo "$line" | sed -n 's/^[^=]*=[[:space:]]*\(.*\)/\1/p')
        value=$(trim "$value")

        case "$key" in
            pkgbase)
                pkgbase_name="$value"
                current_pkg=""
                ;;
            pkgver)
                if [[ -z "$current_pkg" ]]; then
                    global_pkgver="$value"
                fi
                ;;
            pkgrel)
                if [[ -z "$current_pkg" ]]; then
                    global_pkgrel="$value"
                fi
                ;;
            epoch)
                if [[ -z "$current_pkg" ]]; then
                    global_epoch="$value"
                fi
                ;;
            arch)
                if [[ -n "$current_pkg" ]]; then
                    pkg_arch["$current_pkg"]="$value"
                else
                    global_arch="$value"
                fi
                ;;
            pkgname)
                current_pkg="$value"
                pkgnames+=("$current_pkg")
                # 继承全局 arch（可能为空，后续会使用全局值或默认值）
                pkg_arch["$current_pkg"]="${global_arch:-any}"
                ;;
        esac
    done <".SRCINFO"

    # 若无 pkgbase，默认使用第一个包名
    if [[ -z "${pkgbase_name:-}" && ${#pkgnames[@]} -gt 0 ]]; then
        pkgbase_name="${pkgnames[0]}"
    fi

    # 确保必要的全局变量存在
    global_pkgver="${global_pkgver:-}"
    global_pkgrel="${global_pkgrel:-}"
    global_epoch="${global_epoch:-}"

    # 确定删除基准名（多分包用 pkgbase，单包用该包名）
    delete_base=""
    if [[ -n "${pkgbase_name:-}" && "$pkgbase_name" != "${pkgnames[0]}" ]]; then
        delete_base="$pkgbase_name"
        printf "\033[0;36m[NOTE] 多分包: pkgbase='%s', 将以此名称清理旧文件\033[0m\n" "$pkgbase_name"
    else
        delete_base="${pkgnames[0]}"
    fi

    # 生成所有子包的预期文件名列表
    declare -a expected_files=()
    for pkgname in "${pkgnames[@]}"; do
        arch="${pkg_arch[$pkgname]}"
        if [[ -n "$global_epoch" && "$global_epoch" != "0" ]]; then
            f="${pkgname}-${global_epoch}:${global_pkgver}-${global_pkgrel}-${arch}.pkg.tar.zst"
        else
            f="${pkgname}-${global_pkgver}-${global_pkgrel}-${arch}.pkg.tar.zst"
        fi
        expected_files+=("$f")
    done

    # 4. 检查是否需要构建（缺少任意一个预期文件就触发）
    need_build=false
    for ef in "${expected_files[@]}"; do
        if [[ ! -f "${REPO_DIR}/${ef}" ]]; then
            need_build=true
            break
        fi
    done

    if $need_build; then
        printf "\033[0;33m[INFO] 构建 %s ...\033[0m\n" "${pkgbase_name:-$dir_display}"
        if PKGDEST="$REPO_DIR" makepkg -c -f -d; then
            printf "\033[0;32m[MARK] 构建成功: %s\033[0m\n" "$dir_display"

            # 5. 安全删除同一包的旧版本（只删除不属于本次构建的文件）
            declare -A keep_files=()
            for ef in "${expected_files[@]}"; do
                keep_files["$ef"]=1
            done

            while IFS= read -r -d '' cand; do
                cname=$(basename "$cand")
                if [[ -z "${keep_files[$cname]+_}" ]]; then
                    printf "\033[0;35m[INFO] 删除旧版本/无关文件: %s\033[0m\n" "$cname"
                    rm -vf "$cand"
                fi
            done < <(find "$REPO_DIR" -maxdepth 1 \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) -print0 | \
                while IFS= read -r -d '' f; do
                    [[ "$(extract_pkgname "$(basename "$f")")" == "$delete_base" ]] && printf '%s\0' "$f"
                done)
        else
            printf "\033[0;31m[ERROR] 构建失败: %s，保留旧版本不变\033[0m\n" "$dir_display"
            popd >/dev/null
            continue
        fi
    else
        printf "\033[0;34m[NOTE] 所有包已存在，跳过构建: %s\033[0m\n" "$dir_display"
    fi

    popd >/dev/null
done < <(find . -maxdepth 1 -mindepth 1 ! -path "./.git" -type d -print0)

# 6. 更新仓库数据库（添加仓库中所有 .pkg.tar.zst 文件，确保拆分包完整）
shopt -s nullglob
repo_files=("$REPO_DIR"/*.pkg.tar.zst)
if [ ${#repo_files[@]} -gt 0 ]; then
    printf "\033[0;32m[INFO] 更新仓库数据库，包含 %d 个包文件\033[0m\n" "${#repo_files[@]}"
    repo-add "${REPO_DIR}/${DB_NAME}" "${repo_files[@]}"
else
    printf "\033[0;34m[INFO] 仓库目录为空，跳过数据库更新\033[0m\n"
fi
shopt -u nullglob

printf "\033[0;32m[INFO] 所有目录处理完成\033[0m\n"

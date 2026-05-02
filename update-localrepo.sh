#!/bin/bash
set -euo pipefail

REPO_DIR="/mnt/aur/custom/repo"
DB_NAME="aurcustomrepo.db.tar.gz"

# ---------- 工具函数 ----------
# 从包文件名中提取包名（利用 pkgver/pkgrel/arch 不含 '-' 的特性）
extract_pkgname() {
    local filename="$1"
    local name="${filename%.pkg.tar.*}"       # 去掉尾缀
    name="${name%-*}"                         # 去掉 arch
    name="${name%-*}"                         # 去掉 pkgrel
    name="${name%-*}"                         # 去掉 pkgver（包名可包含 '-'）
    basename "$name"
}

# 修剪尾部空白
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ---------- 处理每个目录 ----------
# 收集本次成功构建的包文件（用于最终 repo-add）
built_packages=()

while IFS= read -r -d '' dir; do
    dir_display="${dir#./}"
    printf "\033[0;32m[INFO] 处理目录: %s\033[0m\n" "$dir_display"

    # 检查是否为 meta 包（忽略校验和失败）
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
    current_pkg=""                  # 当前正在解析的 pkgname

    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" == \#* ]] && continue

        # 修剪行首尾空白并归一化等号两侧空格
        key=$(echo "$line" | sed -n 's/^[[:space:]]*\([^[:space:]=]*\)[[:space:]]*=[[:space:]]*.*/\1/p')
        value=$(echo "$line" | sed -n 's/^[^=]*=[[:space:]]*\(.*\)/\1/p')
        # 修剪 value 尾部空白
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
                # 可扩展：记录子包覆盖的 pkgver
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
                # 继承全局 arch（可能为空）
                pkg_arch["$current_pkg"]="${global_arch:-}"
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

    # 4. 处理每个子包
    for pkgname in "${pkgnames[@]}"; do
        arch="${pkg_arch[$pkgname]}"
        # 构造预期包文件名（正确处理 epoch）
        if [[ -n "$global_epoch" && "$global_epoch" != "0" ]]; then
            expected_file="${pkgname}-${global_epoch}:${global_pkgver}-${global_pkgrel}-${arch}.pkg.tar.zst"
        else
            expected_file="${pkgname}-${global_pkgver}-${global_pkgrel}-${arch}.pkg.tar.zst"
        fi
        file_path="${REPO_DIR}/${expected_file}"

        # 确定删除基准名（多分包用 pkgbase，否则用 pkgname）
        if [[ "${pkgbase_name}" != "$pkgname" ]]; then
            delete_base="$pkgbase_name"
            printf "\033[0;36m[NOTE] 多分包: pkgbase='%s', pkgname='%s', 清理时将使用 pkgbase 名称\033[0m\n" \
                "$pkgbase_name" "$pkgname"
        else
            delete_base="$pkgname"
        fi

        if [[ -f "$file_path" ]]; then
            printf "\033[0;34m[NOTE] 包已存在，跳过构建: %s\033[0m\n" "$expected_file"
            continue
        fi

        printf "\033[0;33m[INFO] 构建包: %s\033[0m\n" "$expected_file"

        # 5. 构建包（不预先删除旧文件）
        if PKGDEST="$REPO_DIR" makepkg -c -f -d; then
            printf "\033[0;32m[MARK] 构建成功: %s\033[0m\n" "$pkgname"

            # 记录新生成的文件
            new_file="${REPO_DIR}/${expected_file}"
            if [[ -f "$new_file" ]]; then
                built_packages+=("$new_file")
            else
                printf "\033[0;33m[WARN] 未找到生成的包文件: %s\033[0m\n" "$new_file"
            fi

            # 6. 安全删除该包的其他旧版本（仅删除同一 base 的其他包文件）
            while IFS= read -r -d '' oldfile; do
                oldname=$(basename "$oldfile")
                if [[ "$oldname" != "$expected_file" ]]; then
                    printf "\033[0;35m[INFO] 删除旧版本: %s\033[0m\n" "$oldname"
                    rm -vf "$oldfile"
                fi
            done < <(find "$REPO_DIR" -maxdepth 1 \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) -print0 | \
                while IFS= read -r -d '' f; do
                    candidate_name=$(basename "$f")
                    if [[ "$(extract_pkgname "$candidate_name")" == "$delete_base" ]]; then
                        printf '%s\0' "$f"
                    fi
                done)
        else
            printf "\033[0;31m[ERROR] 构建失败: %s，保留旧版本不变\033[0m\n" "$pkgname"
        fi
    done

    popd >/dev/null
done < <(find . -maxdepth 1 -mindepth 1 ! -path "./.git" -type d -print0)

# 7. 更新仓库数据库（仅添加本次成功构建的包）
if [ ${#built_packages[@]} -gt 0 ]; then
    printf "\033[0;32m[INFO] 更新仓库数据库，包含 %d 个新包\033[0m\n" "${#built_packages[@]}"
    repo-add "${REPO_DIR}/${DB_NAME}" "${built_packages[@]}"
else
    printf "\033[0;34m[INFO] 无新包构建，仓库数据库未更新\033[0m\n"
fi

printf "\033[0;32m[INFO] 所有目录处理完成\033[0m\n"

#!/bin/bash
set -euo pipefail

while IFS= read -r -d '' dir; do
  printf "\033[0;32m[INFO] 处理目录: %s\033[0m\n" "${dir#./}"

  # 检查目录名是否包含"meta"
  is_meta_dir=false
  dir_name="${dir#./}"
  if [[ "$dir_name" == *meta* ]]; then
    is_meta_dir=true
    printf "\033[0;33m[NOTE] 检测到 meta 包, 将忽略校验和错误\033[0m\n"
  fi

  if ! pushd "$dir" >/dev/null; then
    printf "\033[0;31m[ERROR] 无法进入目录: %s\033[0m\n" "$dir"
    continue
  fi

  # 清理变量
  unset pkgnames pkgver pkgrel epoch arch pkgbase
  declare -a pkgnames
  local_epoch=""
  pkgbase_name=""

  # 更新包信息
  if ! updpkgsums; then
    if [ "$is_meta_dir" = false ]; then
      printf "\033[0;31m[ERROR] 更新校验和失败: %s\033[0m\n" "$dir"
      popd >/dev/null
      continue
    else
      printf "\033[0;33m[WARN] meta 包忽略校验和失败: %s\033[0m\n" "$dir"
      # 继续执行，不退出
    fi
  fi

  # 生成.SRCINFO文件
  if ! makepkg --printsrcinfo >".SRCINFO" 2>/dev/null; then
    printf "\033[0;31m[ERROR] 生成 .SRCINFO 失败: %s\033[0m\n" "$dir"
    popd >/dev/null
    continue
  fi

  # 解析.SRCINFO
  while IFS= read -r line; do
    line_trimmed=$(echo "$line" | xargs)
    if [[ "$line_trimmed" =~ ^pkgbase[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      pkgbase_name="${BASH_REMATCH[1]}"
    elif [[ "$line_trimmed" =~ ^pkgver[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      pkgver="${BASH_REMATCH[1]}"
    elif [[ "$line_trimmed" =~ ^pkgrel[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      pkgrel="${BASH_REMATCH[1]}"
    elif [[ "$line_trimmed" =~ ^epoch[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      local_epoch="${BASH_REMATCH[1]}"
    elif [[ "$line_trimmed" =~ ^arch[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      arch="${BASH_REMATCH[1]}"
    elif [[ "$line_trimmed" =~ ^pkgname[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      pkgnames+=("${BASH_REMATCH[1]}")
    fi
  done <".SRCINFO"

  # 如果没有pkgbase，默认使用第一个pkgname
  if [[ -z "$pkgbase_name" && ${#pkgnames[@]} -gt 0 ]]; then
    pkgbase_name="${pkgnames[0]}"
  fi

  # 处理每个包
  for pkgname in "${pkgnames[@]}"; do
    if [[ -n "$local_epoch" ]]; then
      pkgfile="${pkgname}-${local_epoch}:${pkgver}-${pkgrel}-${arch}.pkg.tar.zst"
    else
      pkgfile="${pkgname}-${pkgver}-${pkgrel}-${arch}.pkg.tar.zst"
    fi

    filelocal="/mnt/data/aur/custom/repo/${pkgfile}"

    if [[ ! -f "$filelocal" ]]; then
      printf "\033[0;33m[INFO] 构建包: %s\033[0m\n" "$pkgfile"

      # 确定删除模式：如果pkgbase与pkgname不同，使用pkgbase删除
      delete_pattern=""
      if [[ "$pkgbase_name" != "$pkgname" ]]; then
        printf "\033[0;36m[NOTE] 检测到多分包: pkgbase='%s', pkgname='%s', 使用 pkgbase 删除旧文件\033[0m\n" "$pkgbase_name" "$pkgname"
        delete_pattern="/mnt/data/aur/custom/repo/${pkgbase_name}"
      else
        delete_pattern="/mnt/data/aur/custom/repo/${pkgname}"
      fi

      # 清理旧包文件
      if ls "$delete_pattern"*.pkg.tar.* 2>/dev/null | grep -q .; then
        printf "\033[0;35m[INFO] 删除匹配 %s 的旧文件\033[0m\n" "$delete_pattern*.pkg.tar.*"
        rm -vf "$delete_pattern"*.pkg.tar.* 2>/dev/null
      else
        printf "\033[0;34m[INFO] 没有找到匹配 %s 的旧文件\033[0m\n" "$delete_pattern*.pkg.tar.*"
      fi

      # 构建包
      if PKGDEST="/mnt/data/aur/custom/repo" makepkg -c -f -d; then
        printf "\033[0;32m[MARK] 包构建完成: %s\033[0m\n" "$pkgname"
      else
        printf "\033[0;31m[ERROR] 构建失败: %s\033[0m\n" "$pkgname"
      fi
    fi
    printf "\033[0;34m[NOTE] 包已存在: %s\033[0m\n" "$pkgfile"
  done

  popd >/dev/null
done < <(find . -maxdepth 1 -mindepth 1 ! -path "./.git" -type d -print0)

printf "\033[0;32m[INFO] 所有目录处理完成\033[0m\n"

repo-add /mnt/data/aur/custom/repo/aurcustomrepo.db.tar.gz /mnt/data/aur/custom/repo/*.pkg.tar.zst
printf "\033[0;32m[INFO] 仓库更新完成\033[0m\n"

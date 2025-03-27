#!/bin/bash

# 要执行的命令
COMMAND="makepkg --printsrcinfo > .SRCINFO"

# 要排除的目录列表
EXCLUDED_DIRS=(
  ".git"
)

# 遍历当前目录下的每个子目录
for dir in */; do
  # 检查是否是目录
  if [ -d "$dir" ]; then
    # 检查该目录是否在排除列表中
    skip=false
    for excluded_dir in "${EXCLUDED_DIRS[@]}"; do
      if [ "$dir" = "$EXCLUDED_DIRS[$i]" ]; then
        skip=true
        break
      fi
    done

    # 如果没有排除，则执行命令
    if ! $skip; then
      echo "正在为包 $dir 生成 SRCINFO 文件"
      cd "$dir"
        eval "$COMMAND"
      cd -  # 返回到原来的目录
    fi
  fi
done

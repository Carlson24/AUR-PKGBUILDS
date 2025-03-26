#!/bin/bash

# 要执行的命令
COMMAND="makepkg --printsrcinfo > .SRCINFO"

# 要排除的目录列表
EXCLUDED_DIRS=(
  ".git"
)

# 获取当前目录下的所有子目录
SUBDIRS=$(find . -maxdepth 1 -type d -not -path "./.*")

# 遍历所有子目录
for SUBDIR in $SUBDIRS; do
  # 跳过排除目录
  if [[ ! "$SUBDIR" =~ (^|\/|\.)(./|/)($EXCLUDED_DIRS|)$ ]]; then
    echo "Processing: $SUBDIR"
    cd "$SUBDIR"
    eval "$COMMAND"  # 使用 eval 执行命令，这允许使用变量中的命令
    cd -  # 返回到原始目录
  fi
done

echo "Done processing all subdirectories."

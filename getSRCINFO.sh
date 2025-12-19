#!/usr/bin/bash

# 遍历当前目录下的每个子目录
while IFS= read -r -d '' dir; do
  printf "\033[0;32m[INFO] 进入目录 %s, 更新哈希并生成 .SRCINFO 文件\n\033[0m" "${dir#./}"
  pushd "$dir" >/dev/null || exit
  updpkgsums
  makepkg --printsrcinfo >.SRCINFO
  popd >/dev/null || exit
done < <(find . -maxdepth 1 -mindepth 1 ! -path "./.git" -type d -print0)

#!/bin/bash

PY_VERSION="3.13"
PY_BIN="/Library/Frameworks/Python.framework/Versions/${PY_VERSION}/bin"
PY_APP="/Applications/Python ${PY_VERSION}"
PATH_LINE='export PATH="/Library/Frameworks/Python.framework/Versions/3.13/bin:$PATH"'

echo "正在写入 Python 3.13 PATH 到 ~/.zprofile 和 ~/.bash_profile ..."

grep -qF "$PATH_LINE" ~/.zprofile 2>/dev/null || echo "$PATH_LINE" >> ~/.zprofile
grep -qF "$PATH_LINE" ~/.bash_profile 2>/dev/null || echo "$PATH_LINE" >> ~/.bash_profile

echo "正在让当前脚本环境优先使用 Python 3.13 ..."

export PATH="${PY_BIN}:$PATH"

CURRENT_SHELL=$(ps -p $$ -o comm= | tr -d ' ')

if [ "$CURRENT_SHELL" = "zsh" ]; then
  echo "检测到当前 shell 是 zsh，正在 source ~/.zprofile ..."
  source ~/.zprofile
elif [ "$CURRENT_SHELL" = "bash" ]; then
  echo "检测到当前 shell 是 bash，正在 source ~/.bash_profile ..."
  source ~/.bash_profile
else
  echo "当前 shell 是 ${CURRENT_SHELL}，已在当前脚本内临时 export PATH。"
fi

echo "当前 python3 路径："
which python3

echo "当前 python3 版本："
python3 --version

echo "正在设置 pip 清华源 ..."

python3 -m pip config --user set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
python3 -m pip config --user set global.timeout 60

echo "当前 pip 配置："
python3 -m pip config list

CERT_CMD="${PY_APP}/Install Certificates.command"

if [ -f "$CERT_CMD" ]; then
  echo "正在打开 Install Certificates.command ..."
  open "$CERT_CMD"
else
  echo "没有找到证书脚本：$CERT_CMD"
  echo "请确认你安装的是 python.org 官网的 Python ${PY_VERSION}，并检查 /Applications/Python ${PY_VERSION}/ 目录是否存在。"
fi

echo "完成。"
echo "如果当前终端执行完后 python3 仍然不是 3.13，请关闭终端重新打开，或者手动执行：source ~/.zprofile"

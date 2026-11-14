# 参考补丁（第三方）

`ffyfox-patches/` 来自 GitHub **ffyfox/dsh-desktop-linux**（MIT），仅作为「官方 macOS/Windows 流水线如何移植到 Linux」的参考基线。

本仓库最终交付的 `patches/0001–0010` 是基于它重写并**大幅精简**的版本（删除测试、deb/rpm、AppImage、toolchain 探测、美化 patch），`0011–0016` 为本仓库新增的运行期收敛补丁。运行时**不**直接复用这些参考补丁文件。

来源：https://github.com/ffyfox/dsh-desktop-linux （2026-11-13 master）

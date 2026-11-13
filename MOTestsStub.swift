#if !MO_TESTS
// 发布版不含测试代码（build.sh 排除 *Tests.swift）：这里提供 MOTests.active 恒为 false，
// 各处 if MOTests.active 分支在 -O 下被死代码消除。测试包（MOTEST=1 ./build.sh）编译
// Tests.swift 里的完整实现，此文件条件编译为空。
enum MOTests { static let active = false }
#endif

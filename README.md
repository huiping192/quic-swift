# QUIC Swift

一个基于Swift的QUIC协议学习项目，通过从零实现QUIC协议核心功能，深度学习网络编程、协议设计和Swift并发编程。

## 项目简介

QUIC（Quick UDP Internet Connections）是Google开发的新一代传输协议，已被IETF标准化为RFC 9000。本项目旨在通过实现QUIC协议的核心功能来深入理解：

- 现代网络协议的设计思想
- Swift的网络编程和并发特性
- 传输层协议的实现细节
- 加密和安全通信机制

## 学习路线图

本项目采用渐进式学习方法，分为四个主要阶段：

### 🔵 阶段一：网络编程基础
- UDP Socket编程
- Swift Network.framework使用
- 基础客户端-服务器通信

### 🟡 阶段二：QUIC核心概念
- QUIC包头结构和解析
- 连接ID和版本协商
- 基础握手流程实现

### 🟠 阶段三：流管理
- QUIC流的概念和实现
- 流量控制机制
- 多路复用功能

### 🔴 阶段四：高级特性
- 0-RTT连接建立
- 连接迁移支持
- 拥塞控制算法

## 文档导航

- [QUIC技术概要](documents/quic-overview.md) - QUIC协议的技术背景和核心特性
- [阶段一：网络基础](documents/phase-1-network-basics.md) - Swift网络编程基础
- [阶段二：QUIC核心](documents/phase-2-quic-core.md) - QUIC协议核心概念实现  
- [阶段三：流管理](documents/phase-3-stream-management.md) - 流控制和多路复用
- [阶段四：高级特性](documents/phase-4-advanced-features.md) - 高级QUIC特性
- [学习笔记](documents/learning-notes.md) - 实践心得和问题记录

## 快速开始

```bash
# 克隆项目
git clone https://github.com/your-username/quic-swift.git
cd quic-swift

# 构建项目
swift build

# 运行测试
swift test
```

## 进度追踪

- [ ] 阶段一：网络编程基础
- [ ] 阶段二：QUIC核心概念
- [ ] 阶段三：流管理
- [ ] 阶段四：高级特性

## 贡献和反馈

这是一个学习项目，欢迎提出建议和改进意见。如果你在学习过程中发现问题或有更好的实现方法，欢迎提交Issue或Pull Request。

## 许可证

[MIT License](LICENSE)

## 参考资料

- [RFC 9000: QUIC: A UDP-Based Multiplexed and Secure Transport](https://datatracker.ietf.org/doc/html/rfc9000)
- [RFC 9001: Using TLS to Secure QUIC](https://datatracker.ietf.org/doc/html/rfc9001)
- [Swift Network Framework Documentation](https://developer.apple.com/documentation/network)
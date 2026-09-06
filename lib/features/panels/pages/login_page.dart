import 'package:flutter/material.dart';

/// 登录页（已由 PanelEditPage 的连接测试+保存流程覆盖，保留独立出口便于路由扩展）。
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('登录（已集成在面板编辑页）')));
  }
}

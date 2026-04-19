import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class InteractiveBookPage extends StatefulWidget {
  final String html;
  const InteractiveBookPage({super.key, required this.html});

  @override
  State<InteractiveBookPage> createState() => _InteractiveBookPageState();
}

class _InteractiveBookPageState extends State<InteractiveBookPage> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..loadHtmlString(widget.html);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Interactive Book')),
      body: WebViewWidget(controller: _controller),
    );
  }
}

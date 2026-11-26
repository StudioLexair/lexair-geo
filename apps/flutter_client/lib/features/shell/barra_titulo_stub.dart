import 'package:flutter/material.dart';

class BarraTitulo extends StatelessWidget {
  const BarraTitulo({super.key, this.badge});
  final String? badge;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

BarraTitulo crearBarraTitulo(String? badge) => const BarraTitulo(badge: null);

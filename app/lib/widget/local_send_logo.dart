import 'package:flutter/material.dart';
import 'package:localsend_app/config/tier.dart';
import 'package:localsend_app/gen/assets.gen.dart';

class LocalSendLogo extends StatelessWidget {
  final bool withText;

  const LocalSendLogo({required this.withText});

  @override
  Widget build(BuildContext context) {
    // The logo keeps its own colors: a charcoal tile with the bone arcs and blue flame.
    final logo = Container(
      width: 200,
      height: 200,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2226),
        borderRadius: BorderRadius.circular(46),
      ),
      child: Assets.img.logo512.image(),
    );

    if (withText) {
      return Column(
        children: [
          logo,
          const Text(
            productName,
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else {
      return logo;
    }
  }
}

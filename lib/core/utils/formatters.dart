class CurrencyFormatters {
  static String formatRupiah(num amount) {
    final isNegative = amount < 0;
    final absAmount = amount.abs();
    final whole = absAmount.floor().toString();

    final buffer = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      final positionFromEnd = whole.length - i;
      buffer.write(whole[i]);
      if (positionFromEnd > 1 && positionFromEnd % 3 == 1) {
        buffer.write('.');
      }
    }

    return '${isNegative ? '-' : ''}Rp ${buffer.toString()}';
  }
}

/// Se necesita crear la primera cuenta, sin contraseñas comunes ni por defecto.
class CredencialesInicialesNecesarias implements Exception {
  const CredencialesInicialesNecesarias();
  @override
  String toString() => 'Se necesita configurar la primera cuenta.';
}

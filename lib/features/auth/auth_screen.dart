import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../shared/widgets/glass.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isSignUp = false;
  bool _loading = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.length < 6) {
      setState(() => _error = 'Введи email и пароль (минимум 6 символов)');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });

    final auth = ref.read(authRepositoryProvider);
    try {
      if (_isSignUp) {
        final response = await auth.signUp(email: email, password: password);
        if (response.session == null) {
          setState(() {
            _info = 'Письмо с подтверждением отправлено на $email. Подтверди адрес и войди.';
            _isSignUp = false;
          });
        } else {
          ref.read(sessionControllerProvider.notifier).cachePassword(password);
        }
      } else {
        await auth.signIn(email: email, password: password);
        ref.read(sessionControllerProvider.notifier).cachePassword(password);
      }
    } catch (e) {
      setState(() => _error = humanizeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Сначала введи свой email');
      return;
    }
    setState(() {
      _error = null;
      _info = null;
    });
    try {
      await ref.read(authRepositoryProvider).resetPasswordForEmail(email);
      setState(() => _info = 'Письмо для восстановления пароля отправлено на $email');
    } catch (e) {
      setState(() => _error = humanizeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Albine',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      _isSignUp ? 'Регистрация' : 'Вход в аккаунт',
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isSignUp ? 'Придумай email и пароль' : 'Введите данные для входа',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: glass.textSecondary),
                    ),
                    const SizedBox(height: 28),
                    GlassTextField(
                      label: 'Email',
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      hintText: 'example@mail.com',
                    ),
                    const SizedBox(height: 16),
                    GlassTextField(
                      label: 'Пароль',
                      controller: _passwordController,
                      obscureText: true,
                      hintText: 'Введите пароль',
                      onSubmitted: (_) => _submit(),
                    ),
                    if (!_isSignUp) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: GlassLink(text: 'Забыли пароль?', onTap: _forgotPassword),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      GlassErrorText(_error!),
                    ],
                    if (_info != null) ...[
                      const SizedBox(height: 12),
                      Text(_info!, style: TextStyle(color: glass.link)),
                    ],
                    const SizedBox(height: 24),
                    GlassButton(
                      label: _isSignUp ? 'Зарегистрироваться' : 'Войти',
                      loading: _loading,
                      onPressed: _submit,
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _isSignUp ? 'Уже есть аккаунт?' : 'Нет аккаунта?',
                          style: TextStyle(color: glass.textSecondary),
                        ),
                        const SizedBox(width: 6),
                        GlassLink(
                          text: _isSignUp ? 'Войти' : 'Зарегистрироваться',
                          onTap: () => setState(() {
                            _isSignUp = !_isSignUp;
                            _error = null;
                            _info = null;
                          }),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/app_provider.dart';
import 'pages/login_page.dart';
import 'pages/manager/manager_home.dart';
import 'pages/staff/staff_home.dart';
import 'pages/customer/customer_home.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => AppProvider())],
      child: const FreshFlowApp(),
    ),
  );
}

class FreshFlowApp extends StatelessWidget {
  const FreshFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appProvider = context.read<AppProvider>();

    final GoRouter router = GoRouter(
      initialLocation: '/login',
      refreshListenable: appProvider,
      redirect: (BuildContext context, GoRouterState state) {
        final isLoggedIn = appProvider.role != null;
        final isLoginRoute = state.uri.path == '/login';

        if (!isLoggedIn && !isLoginRoute) {
          return '/login';
        }

        if (isLoggedIn && isLoginRoute) {
          if (appProvider.role == 'manager') return '/manager';
          if (appProvider.role == 'staff') return '/staff';
          if (appProvider.role == 'customer') return '/customer';
        }
        if (isLoggedIn && state.uri.path != '/${appProvider.role}') {
          return '/${appProvider.role}';
        }
        return null;
      },
      routes: <RouteBase>[
        GoRoute(
          path: '/login',
          builder: (BuildContext context, GoRouterState state) {
            return const LoginPage();
          },
        ),
        GoRoute(
          path: '/manager',
          builder: (BuildContext context, GoRouterState state) {
            return const ManagerHome();
          },
        ),
        GoRoute(
          path: '/staff',
          builder: (BuildContext context, GoRouterState state) {
            return const StaffHome();
          },
        ),
        GoRoute(
          path: '/customer',
          builder: (BuildContext context, GoRouterState state) {
            return const CustomerHome();
          },
        ),
      ],
    );

    return MaterialApp.router(
      title: 'FreshFlow — Smart Retail & Food Waste AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF16A34A),
          primary: const Color(0xFF16A34A),
          secondary: const Color(0xFF2563EB),
          error: const Color(0xFFEF4444),
          surface: Colors.white,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Color(0xFF0F172A)),
          titleTextStyle: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: mediaQuery.textScaler.clamp(
              minScaleFactor: 0.8,
              maxScaleFactor: 1.0,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      routerConfig: router,
    );
  }
}

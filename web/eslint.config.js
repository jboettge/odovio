import js from '@eslint/js'
import globals from 'globals'
import pluginVue from 'eslint-plugin-vue'
import security from 'eslint-plugin-security'
import tseslint from 'typescript-eslint'
import vueParser from 'vue-eslint-parser'

export default [
  { ignores: ['dist/**', 'node_modules/**', 'screenshots/**', 'test-results/**', 'playwright-report/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...pluginVue.configs['flat/recommended'],
  security.configs.recommended,
  {
    files: ['**/*.vue'],
    languageOptions: {
      parser: vueParser,
      parserOptions: { parser: tseslint.parser, extraFileExtensions: ['.vue'], sourceType: 'module' },
    },
  },
  {
    files: ['src/**/*.{ts,vue}', 'tests/unit/**/*.ts'],
    languageOptions: { globals: { ...globals.browser } },
    rules: {
      'no-eval': 'error',
      'no-implied-eval': 'error',
      'no-new-func': 'error',
      'no-restricted-properties': [
        'error',
        { property: 'innerHTML', message: 'Kein innerHTML – nur Text-Bindings.' },
        { property: 'outerHTML', message: 'Kein outerHTML.' },
        { property: 'insertAdjacentHTML', message: 'Kein insertAdjacentHTML.' },
      ],
      // Objektzugriffe mit Schlüsseln aus eigenen Konstanten sind hier unkritisch (viele False Positives)
      'security/detect-object-injection': 'off',
      // CSP: keine Inline-Styles
      'vue/no-restricted-syntax': 'off',
      'vue/no-v-html': 'error',
      'vue/multi-word-component-names': 'off',
      'vue/max-attributes-per-line': 'off',
      'vue/singleline-html-element-content-newline': 'off',
      'vue/html-self-closing': 'off',
      'vue/html-indent': 'off',
      'vue/html-closing-bracket-newline': 'off',
      'vue/multiline-html-element-content-newline': 'off',
      'vue/first-attribute-linebreak': 'off',
      'vue/attributes-order': 'off',
      'vue/no-restricted-static-attribute': ['error', 'style'],
      'vue/no-restricted-v-bind': ['error', 'style'],
    },
  },
  {
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_', ignoreRestSiblings: true }],
    },
  },
  {
    files: ['mock/**/*.mjs', 'scripts/**/*.{mjs,d.mts}', 'tests/**/*.{ts,mjs}', '*.config.{js,ts}'],
    languageOptions: { globals: { ...globals.node } },
    rules: {
      // Entwicklungs-/Testwerkzeuge (nicht ausgeliefert): Pfade und Muster stammen aus eigenem Code
      'security/detect-object-injection': 'off',
      'security/detect-non-literal-fs-filename': 'off',
      'security/detect-non-literal-regexp': 'off',
    },
  },
]

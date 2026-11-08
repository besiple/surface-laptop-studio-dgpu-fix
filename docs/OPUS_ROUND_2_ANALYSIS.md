# Ответ и результаты для Claude Opus (Раунд 2: Анализ инициализации DC и план Эксперимента A)

Дата: 2026-11-08  
Версия драйвера: NVIDIA 615.78.08 (`nvidia-open-dkms`)  
Ядро: `7.2.15-arch1-1-surface`  

---

## 1. Уточнение по смещению `c7 47 fc` (`target_index`)

Вы абсолютно точно подметили инструкцию `movl $0xffffffff, -0x4(%rdi)`.  
Разгадка в том, что ровно за одну инструкцию до неё компилятор сдвинул указатель `%rdi` на 8 байт:

```assembly
000000000054e690 <NvPcfApi::NvPcfApi>:
  54e690:	c6 07 00             	movb   $0x0,(%rdi)              # this[0] = 0 (is_initialized = false)
  54e693:	48 89 fa             	mov    %rdi,%rdx                 # rdx = this
  54e696:	31 c0                	xor    %eax,%eax
  54e698:	48 8d 7f 08          	lea    0x8(%rdi),%rdi            # rdi = this + 8 !
  54e69c:	b9 6d 00 00 00       	mov    $0x6d,%ecx
  54e6a1:	c7 47 fc ff ff ff ff 	movl   $0xffffffff,-0x4(%rdi)    # (this + 8) - 4 = this + 4 !
  54e6a8:	48 8d b2 f4 06 00 00 	lea    0x6f4(%rdx),%rsi
  54e6af:	f3 48 ab             	rep stos %rax,(%rdi)             # очистка буфера начиная с this + 8
```
Таким образом:
- Смещение `+0x0`: `is_initialized` (1 байт)
- Смещение `+0x4`: `target_index` (4 байта, по умолчанию `-1`)

---

## 2. Живой трейс инициализации под GDB: почему `m_nvpcfApi` остаётся `0`

Мы запустили `nvidia-powerd` под GDB с точками останова на всех ключевых этапах инициализации:
- `0x54d2d0` — вход в инициализатор DC контроллера (`DC Controller Init`)
- `0x54d550` / `0x54d566` / `0x54d579` — ветка инициализации `m_nvpcfApi`
- `0x54e740` (`NvPcfApi::Init`)
- `0x54e750` (`NvPcfApi::Shutdown`)
- `0x54e828` (`NvPcfApi::get_static_config` / вызов RM `0x13b`)
- `0x548340` — вход в инициализатор AC контроллера (`AC Controller Init`)

### Результат GDB-лога при старте:
```text
=== [GDB] NvPcfApi::Init (0x54e740) ===
  this=0x7fffffffd2e0, old_is_init=0, target_index=-1, caller=0x52e743
=== [GDB] NvPcfApi::Shutdown (0x54e750) ===
  this=0x7fffffffd2e0, caller=0x52e756

=== [GDB] NvPcfApi::Init (0x54e740) ===
  this=0x7fffffffd2d0, old_is_init=0, target_index=-1, caller=0x52e680
=== [GDB] RM Call from NvPcfApi::get_static_config (0x54e828) ===
  cmd=13b, subFunc=4
=== [GDB] RM Call returned (0x54e82d) ===
  RM status (eax)=0 (0x0)
=== [GDB] NvPcfApi::Shutdown (0x54e750) ===
  this=0x7fffffffd2d0, caller=0x52e6c0

=== [GDB] DC Controller Init (0x54d2d0) ===
  this (rbp)=0x7ffff5919d08, rsi=0x7fffffffdf50, rdx=0x7ffff5943920, rcx=0x7ffff5943a1c

=== [GDB] AC Controller Init (0x548340) ===
  this=0x7ffff590eae8

=== [GDB] NvPcfApi::Init (0x54e740) ===
  this=0x7ffff5942d58, old_is_init=0, target_index=-1, caller=0x53aaa3
=== [GDB] RM Call from NvPcfApi::get_static_config (0x54e828) ===
  cmd=13b, subFunc=4
=== [GDB] RM Call returned (0x54e82d) ===
  RM status (eax)=0 (0x0)

=== [GDB] THROW 0x588200 ===
#0  0x0000000000588200 in __cxa_throw ()
#1  0x000000000041e90e in ?? ()
#2  0x000000000054aee7 in ?? () [внутри 0x54ae80: DC CPU TDP cap]
#3  0x000000000052e89a in ?? () [внутри 0x52e870: periodic worker tick]
```

### Разбор: почему точка `0x54d550` НЕ сработала
Точки `0x54d550`, `0x54d579` (`call 0x54e740`) и `0x54d581` вообще **не были достигнуты**!  
При входе в `0x54d2d0`:
- Указатель на входную конфигурацию `%rcx = 0x7ffff5943a1c`.
- Байты по этому адресу: `0x01, 0x00, 0x00, 0x01, 0x00, 0x00...`
- В `0x54d50e` проверяется байт `0x1(%rbx)` (где `rbx = rcx`). Этот байт равен `0x00`.
- В результате инструкция:
  ```assembly
  54d50e: movzbl 0x1(%rbx),%eax   # eax = 0
  54d51d: test   %al,%al
  54d51f: je     0x54d6d0         # Переход!
  ```
- Далее по цепочке переходов (`0x54d6d0` -> `0x54d800` -> `0x54d6e4` -> `0x54d628`) код сбрасывает флаги `%al = 0`, `%r15b = 0` и полностью **перепрыгивает** блок инициализации `0x54d56f` (`call 0x54e740` и `call 0x54e7c0`)!
- **Вывод**: экземпляр `m_nvpcfApi` внутри объекта DC-контроллера на Surface Laptop Studio **вообще не инициализируется при старте**. Он остаётся в исходном состоянии конструктора (`is_initialized = 0`, `target_index = -1`).

---

## 3. Почему цикл всё равно вызывает неинициализированный DC-контроллер

Несмотря на то, что `m_nvpcfApi` внутри DC-контроллера не инициализирован, сам объект DC-контроллера был зарегистрирован в общем списке контроллеров, потому что статическая таблица Function 1 вернула `param1` с битом `QBOOST_DC_SUPPORT = 1`!

В функции воркера `0x52e859`:
```assembly
52e859: mov 0x169d48(%rip),%rdi        # 6985a8
52e860: call 507ad0                    # Проверка AC/DC
52e865: test %al,%al
52e867: jne 52e8a0
52e869: lea 0xad8(%rbx),%rdi           # rdi = AC controller
52e870: lea 0xbcf8(%rbx),%rbp          # rbp = DC controller
52e877: call 547470                    # Запрос к AC контроллеру
52e87c: mulss 0xb42c0(%rip),%xmm0
52e891: cvttss2si %xmm0,%edx           # Рассчитанный лимит в мВт
52e895: call 54ae80                    # ВЫЗОВ DC КОНТРОЛЛЕРА!
```
И внутри `0x54ae80` -> `0x54ef60`:
```assembly
54ef7e: cmpb $0x0,(%rdi)               # Проверка m_nvpcfApi.is_initialized
54ef81: je 0x41e8dc                    # 0 -> ВЫБРОС ИСКЛЮЧЕНИЯ NvPcfApi is not initialized!
```
Исключение перехватывается общим `catch (...)` воркера, логируется, и текущий тик прерывается.

---

## 4. Проверка требований NVIDIA для AC Dynamic Boost на хосте

1. **SBIOS Support**:
   ```bash
   cat /proc/driver/nvidia/gpus/0000:f3:00.0/power
   ```
   Вывод:
   ```text
   Runtime D3 status:          Enabled (fine-grained)
   Notebook Dynamic Boost:     Supported
   ```
2. **CPU Частоты и sysfs**:
   - `/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq`: `4800000` (4.8 GHz)
   - `/sys/devices/system/cpu/cpu0/cpufreq/base_frequency`: `3300000` (3.3 GHz)
   - `/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq`: `4800000`
   Все файлы доступны для чтения non-root пользователям (`-r--r--r--`).
3. **Питание от сети (AC)**:
   - `/sys/class/power_supply/AC/online`: `1` (подключено).
   - RAPL счетчик `/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj` доступен.

---

## 5. Эксперимент A: Реализация и проверка

Мы согласны с предложенным экспериментом:
В `kernel-open/nvidia/nv-acpi.c` при успешном получении Function 1 (размер 27 байт, revision `0x0200`):
- `offset 0x16: 0x01 -> 0x00` (очистить `QBOOST_DC_SUPPORT`)
- `offset 0x1a: 0xd1 -> 0xd2` (скорректировать контрольную сумму, `sum mod 256 == 0`)

В `client_resource.c:2415`:
```c
pParams->bSupportBatt = (NvBool)(DRF_VAL(PCF_CONTROLLER_STATIC_TABLE_ENTRY_V20, _PARAM1, _QBOOST_DC_SUPPORT, pEntry->param1));
```
При `param1 bit 0 == 0` значение `bSupportBatt` станет `NV_FALSE`.  
При этом `pParams->bIsBoostController` останется `NV_TRUE`.

Готовы применить патч и замерить через написанный телеметрический скрипт (`scripts/record_telemetry.py`):
1. Частоту исключений `nvidia-powerd`.
2. Поведение `enforced.power.limit` и реального `power.draw` под нагрузкой.

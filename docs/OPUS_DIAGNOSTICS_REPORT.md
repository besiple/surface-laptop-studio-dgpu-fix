# Диагностический отчет для Claude Opus (Анализ nvidia-powerd на Surface Laptop Studio)

Дата снятия данных: 2026-11-08  
Устройство: Microsoft Surface Laptop Studio (1st Gen)  
GPU: NVIDIA GeForce RTX 3050 Ti Mobile (GA107M, PCI ID `10de:25a0`, Subsystem `1414:0054`)  
Ядро: `7.2.15-arch1-1-surface`  
Драйвер NVIDIA: `615.78.08` (`nvidia-open-dkms` с патчем подмены маски Func 0 и моком Subfunc 8)  

---

## 1. Базовые данные системы и драйвера

### `nvidia-smi`
```text
Sun Nov  8 11:47:28 2026       
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 615.78.08              KMD Version: 615.78.08     CUDA UMD Version: 13.4     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA GeForce RTX 3050 ...    On  |   00000000:F3:00.0 Off |                  N/A |
| N/A   49C    P8              3W /   35W |     195MiB /   4096MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+
```

### `uname -r`
```text
7.2.15-arch1-1-surface
```

### `modinfo -F version nvidia`
```text
615.78.08
```

### `sha256sum /usr/bin/nvidia-powerd`
```text
3d788e147dc9c22d114943d35aa4be02fe1672f3d51bfcecf39c1b8e4cb00dcb  /usr/bin/nvidia-powerd
```

---

## 2. Поведение демона и первичная последовательность ошибок

### Статус `systemctl status nvidia-powerd`
Процесс **НЕ завершается** и **НЕ падает**. Он стабильно крутится в статусе `active (running)`, имеет 5 потоков, потребляет ~3.8 MB памяти и бесконечно ловит исключение в цикле воркера:

```text
● nvidia-powerd.service - nvidia-powerd service
     Loaded: loaded (/usr/lib/systemd/system/nvidia-powerd.service; enabled; preset: disabled)
     Active: active (running) since Sun 2026-11-08 11:16:51 EET; 30min ago
   Main PID: 56162 (nvidia-powerd)
      Tasks: 5 (limit: 18778)
     Memory: 3.8M (peak: 5.8M)
        CPU: 23.139s
     CGroup: /system.slice/nvidia-powerd.service
             └─56162 /usr/bin/nvidia-powerd
```

### `journalctl -b -u nvidia-powerd -o short-monotonic --no-pager`
Строки **до первого** `NvPcfApi is not initialized`:
```text
[    5.290602] surface-arch systemd[1]: Started nvidia-powerd service.
[    5.299597] surface-arch nvidia-powerd[502]: nvidia-powerd version:2.0 (build 1)
[    5.305074] surface-arch nvidia-powerd[502]: DBus Connection is established
[   15.671184] surface-arch nvidia-powerd[502]: ERROR! Exception NvPcfApi is not initialized
[   65.754825] surface-arch nvidia-powerd[502]: ERROR! Exception NvPcfApi is not initialized
...
```
Между `DBus Connection is established` и первым исключением проходит ровно ~10 секунд. Далее ошибки сыплются периодически с интервалом от 2 до 30 секунд (в зависимости от нагрузки и таймера семплирования).

### `journalctl -b -k -o short-monotonic --no-pager | grep -Ei 'nvrm|nvpcf'`
```text
[    3.514087] surface-arch kernel: NVRM: Patching Surface NVPCF Function 0 mask from 0xc7 to 0xFF
[    3.514139] surface-arch kernel: NVRM: Patching Surface NVPCF Function 0 mask from 0x01 to 0xFF
[    4.908022] surface-arch kernel: NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  615.78.08  Release Build  (root@)  
[    5.310039] surface-arch kernel: NVRM: Synthesized Surface DC Power Limits Table for NVPCF Subfunc 8
[    5.333013] surface-arch kernel: NVRM: Synthesized Surface DC Power Limits Table for NVPCF Subfunc 8
```
Обратите внимание: ядро дважды синтезирует Subfunc 8 при инициализации (на 5.310s и 5.333s), сразу после старта сервиса.

---

## 3. ELF-структура `/usr/bin/nvidia-powerd`

Бинарник скомпилирован как `EXEC` (не PIE/DYN) с фиксированной базой `0x400000`:

```text
ELF Header:
  Class:                             ELF64
  Data:                              2's complement, little endian
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Entry point address:               0x42b568

Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  PHDR           0x000040 0x0000000000400040 0x0000000000400040 0x0002a0 0x0002a0 R   0x8
  INTERP         0x0002e0 0x00000000004002e0 0x00000000004002e0 0x00001c 0x00001c R   0x1
  LOAD           0x000000 0x0000000000400000 0x0000000000400000 0x004698 0x004698 R   0x1000
  LOAD           0x005000 0x0000000000405000 0x0000000000405000 0x1da9c2 0x1da9c2 R E 0x1000
  LOAD           0x1e0000 0x00000000005e0000 0x00000000005e0000 0x08b985 0x08b985 R   0x1000
  LOAD           0x26c470 0x000000000066d470 0x000000000066d470 0x028260 0x02e510 RW  0x1000
  DYNAMIC        0x291620 0x0000000000692620 0x0000000000692620 0x000210 0x000210 RW  0x8
```

---

## 4. Дизассемблирование запрошенного участка `0x41e5d0` - `0x41e6b0`

```assembly
000000000041e5d0 <.text+0x186e0>:
  41e5d0:	4c 89 e7             	mov    %r12,%rdi
  41e5d3:	e8 d8 46 1a 00       	call   5c2cb0
  41e5d8:	e9 02 ff ff ff       	jmp    41e4df
  41e5dd:	4c 89 e7             	mov    %r12,%rdi
  41e5e0:	48 89 c5             	mov    %rax,%rbp
  41e5e3:	e8 c8 46 1a 00       	call   5c2cb0
  41e5e8:	4c 89 f7             	mov    %r14,%rdi
  41e5eb:	e8 c0 46 1a 00       	call   5c2cb0
  41e5f0:	4c 89 ef             	mov    %r13,%rdi
  41e5f3:	e8 88 8e 16 00       	call   587480
  41e5f8:	48 89 ef             	mov    %rbp,%rdi
  41e5fb:	e8 00 ed 1b 00       	call   5dd300
  41e600:	48 89 c5             	mov    %rax,%rbp
  41e603:	eb e3                	jmp    41e5e8
  41e605:	48 89 c5             	mov    %rax,%rbp
  41e608:	eb e6                	jmp    41e5f0
  41e60a:	bf 10 00 00 00       	mov    $0x10,%edi
  41e60f:	e8 0c 8e 16 00       	call   587420
  41e614:	48 8d 35 45 d0 1d 00 	lea    0x1dd045(%rip),%rsi        # 0x5fb660 ("Error in getting the NvPCF static configuration")
  41e61b:	48 89 c7             	mov    %rax,%rdi
  41e61e:	49 89 c4             	mov    %rax,%r12
  41e621:	e8 da 8c 17 00       	call   597300
  41e626:	48 c7 c2 70 0e 59 00 	mov    $0x590e70,%rdx
  41e62d:	48 c7 c6 60 ee 68 00 	mov    $0x68ee60,%rsi
  41e634:	4c 89 e7             	mov    %r12,%rdi
  41e637:	e8 c4 9b 16 00       	call   588200                     # __cxa_throw!
  41e63c:	bf 10 00 00 00       	mov    $0x10,%edi
  41e641:	e8 da 8d 16 00       	call   587420
  41e646:	48 8d 35 f3 cf 1d 00 	lea    0x1dcff3(%rip),%rsi        # 0x5fb640 ("NvPcfApi is not initialized")
  41e64d:	48 89 c7             	mov    %rax,%rdi
  41e650:	49 89 c4             	mov    %rax,%r12
  41e653:	e8 a8 8c 17 00       	call   597300
  41e658:	48 c7 c2 70 0e 59 00 	mov    $0x590e70,%rdx
  41e65f:	48 c7 c6 60 ee 68 00 	mov    $0x68ee60,%rsi
  41e666:	4c 89 e7             	mov    %r12,%rdi
  41e667:	e8 92 9b 16 00       	call   588200                     # __cxa_throw!
  41e66e:	48 89 c5             	mov    %rax,%rbp
  41e671:	4c 89 e7             	mov    %r12,%rdi
  41e674:	e8 07 8e 16 00       	call   587480
  41e679:	48 89 ef             	mov    %rbp,%rdi
  41e67c:	e8 7f ec 1b 00       	call   5dd300
  41e681:	48 89 c5             	mov    %rax,%rbp
  41e684:	4c 89 e7             	mov    %r12,%rdi
  41e687:	e8 f4 8d 16 00       	call   587480
  41e68c:	48 89 ef             	mov    %rbp,%rdi
  41e68f:	e8 6c ec 1b 00       	call   5dd300
  41e694:	bf 10 00 00 00       	mov    $0x10,%edi
  41e699:	e8 82 8d 16 00       	call   587420
  41e69e:	48 8d 35 eb cf 1d 00 	lea    0x1dcfeb(%rip),%rsi        # 0x5fb690 ("Failed to get SysPwrLimitGetInfo")
  41e6a5:	48 89 c7             	mov    %rax,%rdi
  41e6a8:	48 89 c5             	mov    %rax,%rbp
  41e6ab:	e8 50 8c 17 00       	call   597300
```

---

## 5. Точный стек вызова живого процесса (GDB Backtrace)

Мы подключились GDB к работающему процессу `nvidia-powerd` (PID 56162) и установили точку останова на внутреннюю функцию генерации исключения `0x588200` (`__cxa_throw`).

Точка останова успешно сработала:
```text
Thread 1 "nvidia-powerd" hit Breakpoint 1, 0x0000000000588200 in ?? ()
#0  0x0000000000588200 in ?? ()
#1  0x000000000041e90e in ?? ()
#2  0x000000000054aee7 in ?? ()
#3  0x000000000052e89a in ?? ()
#4  0x00000000004eed95 in ?? ()
#5  0x00000000004ef749 in ?? ()
#6  0x00000000004248db in ?? ()
#7  0x00007f417a027781 in ?? () from /usr/lib/libc.so.6
#8  0x00007f417a0278b9 in __libc_start_main () from /usr/lib/libc.so.6
#9  0x000000000042b591 in ?? ()
```

### Анализ стека:
1. **Кадр #4 (`0x4eed95`) и #5 (`0x4ef749`)**:
   Основной цикл планировщика `nvidia-powerd`. Итерируется по зарегистрированным контроллерам питания:
   ```assembly
   4eed8f: mov (%rdi),%rax
   4eed92: call *0x70(%rax)    # Вызов виртуального метода 0x70 (контроллер питания)
   ```
2. **Кадр #3 (`0x52e89a`)**:
   Метод `0x70` контроллера **DC (Battery Power Controller)**:
   ```assembly
   52e870: lea 0xbcf8(%rbx),%rbp   # rbp = DC controller instance
   52e877: call 547470             # Расчет допустимого TDP
   52e891: cvttss2si %xmm0,%edx    # Значение TDP в милливаттах
   52e895: call 54ae80             # Вызов применения лимита
   ```
3. **Кадр #2 (`0x54aee7`)**:
   Функция `0x54ae80` (применение DC CPU TDP Cap):
   ```assembly
   54aed6: lea 0x1d0(%rbx),%rdi    # rdi = &this->m_nvpcfApi (экземпляр API NVPCF в объекте DC)
   54aee2: call 54ef60             # Вызов NvPcfApi::SetDcCpuTdpCap
   ```
4. **Кадр #1 (`0x41e90e`)**:
   Внутри `0x54ef60` проверяется флаг инициализации `m_nvpcfApi`:
   ```assembly
   54ef7e: cmpb $0x0,(%rdi)        # Проверка m_nvpcfApi.is_initialized
   54ef81: je 41e8dc               # Если 0 -> ПЕРЕХОД НА ВЫБРОС ИСКЛЮЧЕНИЯ!
   ```
   А по адресу `0x41e8dc`:
   ```assembly
   41e8e6: lea 0x1dcd53(%rip),%rsi # 0x5fb640 ("NvPcfApi is not initialized")
   41e909: call 588200            # __cxa_throw
   41e90e: <возврат / landing pad>
   ```

---

## 6. Первопричина: почему `m_nvpcfApi.is_initialized == false`?

В бинарнике класс `NvPcfApi` имеет следующие смещения:
- `+0x0`: `uint8_t is_initialized` (`0` = не инициализирован, `1` = инициализирован)
- `+0x4`: `int32_t target_index` (`-1` = невалидный, `>=0` = валидный)

Конструктор `0x54e690` инициализирует:
```assembly
c6 07 00              movb $0x0, (%rdi)       # is_initialized = 0
c7 47 fc ff ff ff ff  movl $0xffffffff, 0x4(%rdi) # target_index = -1
```

Объект `NvPcfApi` внутри DC контроллера (`0x1d0(%rbp)`) на этапе инициализации системы (`0x54d550`):
1. Пытается вызвать `0x54e740` (Set Init = 1) и затем `0x54e7c0` (чтение статической конфигурации через IOCTL RM `0x13b` / NVPCF Function 1).
2. Если контроллер не удовлетворяет условиям (или проверка `test %r15b, %r15b` в `0x54d566` не проходит, либо `is_valid_target_index()` возвращает 0), он переходит в `0x54d64d` в обход полной инициализации.
3. Позже, при штатном вызове деструктора или сброса контроллера, вызывается `0x54e750`, которая явно сбрасывает:
   ```assembly
   54e75c: movb $0x0, (%rdi)   # is_initialized = false
   ```
4. В результате DC контроллер остается в неинициализированном состоянии, но таймер тиков главного цикла продолжает каждые несколько секунд опрашивать `*0x70(%rax)`, вызывая метод `0x54ae80` -> `0x54ef60`, где проверка `cmpb $0x0, (%rdi)` немедленно выбрасывает `NvPcfApi is not initialized`.

---

## 7. Вывод по гипотезам

1. **NOP на `__cxa_throw` действительно недопустим**: как мы выяснили, `54ef81: je 41e8dc` переходит в отдельный cold-блок выброса исключения. Если убрать throw, код провалится в инструкцию возврата landing-пада или мусорные байты, повредив стек.
2. **AC Dynamic Boost vs DC Controller**:
   Ошибка происходит строго внутри **DC (Battery) контроллера питания**. Surface Laptop Studio физически не имеет в DSDT/SSDT таблицы Function 8 (DC limits). Наш DKMS mock таблицы 8 позволяет пройти проверку NVRM ядра, но структура/версия этой таблицы (в коде 615.xx требующая версию контроллера `>= 0x22`, тогда как Surface отдает `0x21`) не переводит DC-контроллер в валидное состояние `is_initialized = 1, target_index >= 0`.
3. **Что нужно для 50W под AC**:
   Поскольку ноутбук подключен к блоку питания (AC), нам требуется, чтобы работал AC Dynamic Boost (или прямой target TPP 50W через `SPWR = 0x0320` в ACPI). Сейчас же ошибка DC-пути не роняет сервис, но захламляет лог и может препятствовать включению Dynamic Boost.

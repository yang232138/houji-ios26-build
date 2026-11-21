/* SPDX-License-Identifier: BSD-2-Clause-Patent */
#include <Uefi.h>
#include <PiDxe.h>
#include <Guid/DxeServices.h>
#include <Protocol/Cpu.h>
#include "HandoffReadPolicy.h"
#include "UfsOwnerCheck.h"

STATIC EFI_SYSTEM_TABLE *mSystem;
STATIC EFI_GUID mCpuGuid = EFI_CPU_ARCH_PROTOCOL_GUID;
STATIC CONST EFI_GUID mDxeGuid = DXE_SERVICES_TABLE_GUID;
STATIC volatile BOOLEAN mReadArmed;
STATIC volatile BOOLEAN mReadAborted;
STATIC volatile UINT64 mReadAddress;

STATIC VOID
Say (CONST CHAR16 *Text)
{
  if (mSystem->ConOut != NULL) {
    mSystem->ConOut->OutputString (mSystem->ConOut, (CHAR16 *)Text);
  }
}

STATIC VOID
SayHex (CONST CHAR16 *Label, UINT32 Value)
{
  STATIC CONST CHAR16 Hex[] = L"0123456789ABCDEF";
  CHAR16 Digits[9];
  for (UINTN Index = 0; Index < 8; Index++) {
    Digits[Index] = Hex[(Value >> (28U - 4U * Index)) & 0xFU];
  }
  Digits[8] = 0;
  Say (Label);
  Say (Digits);
}

STATIC VOID
ShowQueueSnapshot (CONST HOUJI_OWNER_HCI_SNAPSHOT *Hci)
{
  SayHex (L" IS=", Hci->InterruptStatus);
  SayHex (L"  IE=", Hci->Queue[HoujiQueueInterruptEnable]);
  Say (L"\r\n");
  SayHex (L" TR DB=", Hci->Queue[HoujiQueueTransferDoorbell]);
  SayHex (L"  RUN=", Hci->Queue[HoujiQueueTransferRun]);
  Say (L"\r\n");
  SayHex (L" TM DB=", Hci->Queue[HoujiQueueTaskDoorbell]);
  SayHex (L"  RUN=", Hci->Queue[HoujiQueueTaskRun]);
  Say (L"\r\n");
  // Report whether each base is populated without printing DMA addresses.
  Say ((Hci->Queue[HoujiQueueTransferBaseLow] | Hci->Queue[HoujiQueueTransferBaseHigh]) ?
    L" TR BASE=SET" : L" TR BASE=ZERO");
  Say ((Hci->Queue[HoujiQueueTaskBaseLow] | Hci->Queue[HoujiQueueTaskBaseHigh]) ?
    L"  TM BASE=SET\r\n" : L"  TM BASE=ZERO\r\n");
}

STATIC VOID __attribute__((noreturn))
Stop (VOID)
{
  for (;;) { __asm__ volatile ("wfe"); }
}

STATIC UINT32 __attribute__((naked, noinline))
ReadMmioStub (UINT64 Address)
{
  __asm__ volatile ("ldr w0, [x0]\n\tret");
}

STATIC VOID EFIAPI
ReadException (EFI_EXCEPTION_TYPE Type, EFI_SYSTEM_CONTEXT Context)
{
  EFI_SYSTEM_CONTEXT_AARCH64 *State = Context.SystemContextAArch64;
  if (Type != EXCEPT_AARCH64_SYNCHRONOUS_EXCEPTIONS ||
      !HandoffFaultExpected (mReadArmed, (UINTN)ReadMmioStub, mReadAddress,
        State->ELR, State->ESR, State->FAR, *(CONST UINT32 *)(UINTN)ReadMmioStub)) {
    Stop ();
  }
  mReadAborted = TRUE;
  State->X0 = 0;
  State->ELR += 4;
}

STATIC BOOLEAN
ReadRegister (VOID *Context, UINT64 Address, UINT32 *Value)
{
  (VOID)Context;
  if (!HandoffAddressAllowed (Address) || mReadArmed) { return FALSE; }
  mReadAddress = Address;
  mReadAborted = FALSE;
  mReadArmed = TRUE;
  __asm__ volatile ("dsb sy" ::: "memory");
  UINT32 Result = ReadMmioStub (Address);
  __asm__ volatile ("dsb sy" ::: "memory");
  mReadArmed = FALSE;
  if (mReadAborted) { return FALSE; }
  *Value = Result;
  return TRUE;
}

STATIC EFI_DXE_SERVICES *
GetDxeServices (VOID)
{
  for (UINTN Table = 0; Table < mSystem->NumberOfTableEntries; Table++) {
    CONST EFI_CONFIGURATION_TABLE *Entry = &mSystem->ConfigurationTable[Table];
    CONST UINT8 *Expected = (CONST UINT8 *)&mDxeGuid;
    CONST UINT8 *Actual = (CONST UINT8 *)&Entry->VendorGuid;
    UINTN Index = 0;
    while (Index < sizeof (EFI_GUID) && Actual[Index] == Expected[Index]) { Index++; }
    if (Index == sizeof (EFI_GUID)) { return Entry->VendorTable; }
  }
  return NULL;
}

STATIC BOOLEAN
CheckDeviceWindow (EFI_DXE_SERVICES *Dxe, UINT64 Base, UINT64 Bytes)
{
  for (UINT64 Address = Base; Address < Base + Bytes; Address += EFI_PAGE_SIZE) {
    EFI_GCD_MEMORY_SPACE_DESCRIPTOR Descriptor;
    UINT64 Par;
    __asm__ volatile ("at s1e1r, %1\n\tisb\n\tmrs %0, par_el1" : "=r" (Par) : "r" (Address) : "memory");
    if ((Par & 1) || (Par & 0x0000FFFFFFFFF000ULL) != Address || (Par >> 56) > 0xC ||
        EFI_ERROR (Dxe->GetMemorySpaceDescriptor (Address, &Descriptor)) ||
        Descriptor.GcdMemoryType != EfiGcdMemoryTypeMemoryMappedIo) {
      return FALSE;
    }
  }
  return TRUE;
}

EFI_STATUS EFIAPI
UniXNUApplicationEntry (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  (VOID)ImageHandle;
  mSystem = SystemTable;
  Say (L"\r\nHOUJI UFS OWNER PREFLIGHT\r\n");
  const UINT32 *Instructions = (CONST UINT32 *)(UINTN)ReadMmioStub;
  UINT64 El, SavedPar;
  __asm__ volatile ("mrs %0, CurrentEL" : "=r" (El));
  if (El != 4 || Instructions[0] != 0xB9400000U || Instructions[1] != 0xD65F03C0U) {
    Say (L"STOP: firmware execution state or guarded load\r\n");
    Stop ();
  }
  EFI_DXE_SERVICES *Dxe = GetDxeServices ();
  __asm__ volatile ("mrs %0, par_el1" : "=r" (SavedPar));
  BOOLEAN MapOk = Dxe != NULL && CheckDeviceWindow (Dxe, HOUJI_OWNER_HCI_BASE, EFI_PAGE_SIZE) &&
    CheckDeviceWindow (Dxe, HOUJI_OWNER_SMMU_BASE, HOUJI_OWNER_SMMU_SIZE);
  __asm__ volatile ("msr par_el1, %0\n\tisb" :: "r" (SavedPar) : "memory");
  if (!MapOk) {
    Say (L"STOP: HCI or SMMU device mapping\r\n");
    Stop ();
  }

  EFI_CPU_ARCH_PROTOCOL *Cpu = NULL;
  EFI_BOOT_SERVICES *Boot = mSystem->BootServices;
  if (EFI_ERROR (Boot->LocateProtocol (&mCpuGuid, NULL, (VOID **)&Cpu)) || Cpu == NULL ||
      EFI_ERROR (Cpu->RegisterInterruptHandler (Cpu, EXCEPT_AARCH64_SYNCHRONOUS_EXCEPTIONS, ReadException))) {
    Say (L"STOP: guarded MMIO unavailable\r\n");
    Stop ();
  }
  HOUJI_OWNER_HCI_SNAPSHOT Hci;
  HOUJI_OWNER_RESULT Result = HoujiOwnerInspect (ReadRegister, NULL, &Hci);
  if (EFI_ERROR (Cpu->RegisterInterruptHandler (Cpu, EXCEPT_AARCH64_SYNCHRONOUS_EXCEPTIONS, NULL))) {
    Say (L"STOP: restore firmware exception handler\r\n");
    Stop ();
  }

  STATIC CONST CHAR16 *CONST Message[] = {
    [HoujiOwnerReadFailed] = L"STOP: guarded register read failed\r\n",
    [HoujiOwnerLinkNotReady] = L"STOP: HCI or link not ready\r\n",
    [HoujiOwnerMcq] = L"STOP: MCQ active\r\n",
    [HoujiOwnerHciFault] = L"STOP: HCI error status\r\n",
    [HoujiOwnerQueueNotRetired] = L"STOP: legacy queues not clean and stopped\r\n",
    [HoujiOwnerSmmuPolicyUnknown] = L"STOP: SMMU policy or fault\r\n",
    [HoujiOwnerSidMissingOrAmbiguous] = L"STOP: SID 0x60 missing or ambiguous\r\n",
    [HoujiOwnerBankNotIsolated] = L"STOP: SID 0x60 context unavailable\r\n",
    [HoujiOwnerSidFaulting] = L"STOP: SID 0x60 configured to fault\r\n",
    [HoujiOwnerTranslationObserved] = L"OBSERVED: queues idle, SID 0x60 translating, ownership unproven\r\n",
  };
  Say (Message[Result]);
  if (Result == HoujiOwnerQueueNotRetired) {
    ShowQueueSnapshot (&Hci);
  } else if (Result == HoujiOwnerHciFault) {
    SayHex (L" IS=", Hci.InterruptStatus);
    Say (L"\r\n");
  }
  Say (L"UFS PREFLIGHT END - NO STORAGE COMMAND\r\n");
  Stop ();
}

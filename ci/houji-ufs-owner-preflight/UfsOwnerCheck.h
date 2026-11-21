/* SPDX-License-Identifier: BSD-2-Clause-Patent */
#ifndef HOUJI_UFS_OWNER_CHECK_H
#define HOUJI_UFS_OWNER_CHECK_H

#define HOUJI_OWNER_HCI_BASE  0x01D84000U
#define HOUJI_OWNER_SMMU_BASE 0x15000000U
#define HOUJI_OWNER_SMMU_SIZE 0xD0000U

typedef BOOLEAN (*HOUJI_OWNER_READ)(VOID *Context, UINT64 Address, UINT32 *Value);

typedef enum {
  HoujiOwnerReadFailed,
  HoujiOwnerLinkNotReady,
  HoujiOwnerMcq,
  HoujiOwnerHciFault,
  HoujiOwnerQueueNotRetired,
  HoujiOwnerSmmuPolicyUnknown,
  HoujiOwnerSidMissingOrAmbiguous,
  HoujiOwnerBankNotIsolated,
  HoujiOwnerSidFaulting,
  HoujiOwnerTranslationObserved
} HOUJI_OWNER_RESULT;

typedef enum {
  HoujiQueueInterruptEnable,
  HoujiQueueTransferDoorbell,
  HoujiQueueTransferRun,
  HoujiQueueTaskDoorbell,
  HoujiQueueTaskRun,
  HoujiQueueTransferBaseLow,
  HoujiQueueTransferBaseHigh,
  HoujiQueueTaskBaseLow,
  HoujiQueueTaskBaseHigh,
  HoujiQueueRegisterCount
} HOUJI_OWNER_QUEUE_REGISTER;

typedef struct {
  UINT32 InterruptStatus;
  UINT32 Queue[HoujiQueueRegisterCount];
} HOUJI_OWNER_HCI_SNAPSHOT;

STATIC HOUJI_OWNER_RESULT
HoujiOwnerInspect (HOUJI_OWNER_READ Read, VOID *Context, HOUJI_OWNER_HCI_SNAPSHOT *Hci)
{
  STATIC CONST UINT32 QueueRegisters[HoujiQueueRegisterCount] = {
    [HoujiQueueInterruptEnable] = 0x24,
    [HoujiQueueTransferDoorbell] = 0x58,
    [HoujiQueueTransferRun] = 0x60,
    [HoujiQueueTaskDoorbell] = 0x78,
    [HoujiQueueTaskRun] = 0x80,
    [HoujiQueueTransferBaseLow] = 0x50,
    [HoujiQueueTransferBaseHigh] = 0x54,
    [HoujiQueueTaskBaseLow] = 0x70,
    [HoujiQueueTaskBaseHigh] = 0x74,
  };
  UINT32 Caps, Value;
  if (!Read (Context, HOUJI_OWNER_HCI_BASE, &Caps) ||
      !Read (Context, HOUJI_OWNER_HCI_BASE + 0x34, &Value)) { return HoujiOwnerReadFailed; }
  if (!(Value & 1U)) { return HoujiOwnerLinkNotReady; }
  if (!Read (Context, HOUJI_OWNER_HCI_BASE + 0x30, &Value)) { return HoujiOwnerReadFailed; }
  if ((Value & 0xFU) != 0xFU) { return HoujiOwnerLinkNotReady; }
  if (Caps & (1U << 30)) {
    if (!Read (Context, HOUJI_OWNER_HCI_BASE + 0x300, &Value)) { return HoujiOwnerReadFailed; }
    if (Value & 1U) { return HoujiOwnerMcq; }
  }
  if (!Read (Context, HOUJI_OWNER_HCI_BASE + 0x20, &Hci->InterruptStatus)) { return HoujiOwnerReadFailed; }
  if (Hci->InterruptStatus & 0x71880U) { return HoujiOwnerHciFault; }
  // Take one bounded snapshot of the legacy register set. If any queue
  // state is inherited, stop before SMMU observation or command submission.
  UINT32 QueueState = 0;
  for (UINTN Index = 0; Index < ARRAY_SIZE (QueueRegisters); Index++) {
    if (!Read (Context, HOUJI_OWNER_HCI_BASE + QueueRegisters[Index], &Hci->Queue[Index])) {
      return HoujiOwnerReadFailed;
    }
    QueueState |= Hci->Queue[Index];
  }
  if (QueueState != 0) { return HoujiOwnerQueueNotRetired; }

  UINT32 Id0, Id1;
  if (!Read (Context, HOUJI_OWNER_SMMU_BASE + 0x20, &Id0) ||
      !Read (Context, HOUJI_OWNER_SMMU_BASE + 0x24, &Id1)) { return HoujiOwnerReadFailed; }
  UINT32 Groups = Id0 & 0xFFU;
  UINT32 Banks = Id1 & 0xFFU;
  UINT32 Pages = 2U << ((Id1 >> 28) & 7U);
  // Recognize only legacy stream matching and a bounded 4 KiB register stride.
  if (!(Id0 & (1U << 27)) || (Id0 & (1U << 8)) || (Id1 >> 31) ||
      Groups == 0 || Groups > 128 || Banks < 2 || Banks > 128 ||
      (Pages + Banks) * 4096U > HOUJI_OWNER_SMMU_SIZE) { return HoujiOwnerSmmuPolicyUnknown; }
  if (!Read (Context, HOUJI_OWNER_SMMU_BASE, &Value)) { return HoujiOwnerReadFailed; }
  // Clients enabled, fault reporting enabled, unknown streams fault, EXID disabled.
  if ((Value & 0x40FU) != 0x406U) { return HoujiOwnerSmmuPolicyUnknown; }
  if (!Read (Context, HOUJI_OWNER_SMMU_BASE + 0x48, &Value)) { return HoujiOwnerReadFailed; }
  if (Value != 0) { return HoujiOwnerSmmuPolicyUnknown; }

  UINT32 TranslatedStreams[128] = {0};
  BOOLEAN Found = FALSE;
  UINT32 UfsRoute = 0;
  for (UINT32 Index = 0; Index < Groups; Index++) {
    UINT32 Match, Route;
    if (!Read (Context, HOUJI_OWNER_SMMU_BASE + 0x800U + 4U * Index, &Match)) {
      return HoujiOwnerReadFailed;
    }
    if (!(Match & (1U << 31))) { continue; }
    UINT32 Mask = (Match >> 16) & 0x7FFFU;
    BOOLEAN MatchesUfs = ((Match ^ 0x60U) & 0xFFFFU & ~Mask) == 0;
    if (MatchesUfs && (Found || Mask != 0)) { return HoujiOwnerSidMissingOrAmbiguous; }
    if (!Read (Context, HOUJI_OWNER_SMMU_BASE + 0xC00U + 4U * Index, &Route)) {
      return HoujiOwnerReadFailed;
    }
    UINT32 Type = (Route >> 16) & 3U;
    UINT32 Bank = Route & 0xFFU;
    if (Type == 3 || (Type == 0 && Bank >= Banks)) { return HoujiOwnerSmmuPolicyUnknown; }
    if (Type == 0) { TranslatedStreams[Bank]++; }
    if (MatchesUfs) { Found = TRUE; UfsRoute = Route; }
  }
  if (!Found) { return HoujiOwnerSidMissingOrAmbiguous; }
  UINT32 Type = (UfsRoute >> 16) & 3U;
  UINT32 Bank = UfsRoute & 0xFFU;
  if (Type == 2) { return HoujiOwnerSidFaulting; }
  if (Type != 0 || TranslatedStreams[Bank] != 1) { return HoujiOwnerBankNotIsolated; }

  UINT64 ContextBank = HOUJI_OWNER_SMMU_BASE + (Pages + Bank) * 4096U;
  if (!Read (Context, ContextBank, &Value)) { return HoujiOwnerReadFailed; }
  if (!(Value & 1U)) { return HoujiOwnerBankNotIsolated; }
  if (!Read (Context, ContextBank + 0x58, &Value)) { return HoujiOwnerReadFailed; }
  if (Value & 0xC00001FEU) { return HoujiOwnerSmmuPolicyUnknown; }
  return HoujiOwnerTranslationObserved;
}
#endif

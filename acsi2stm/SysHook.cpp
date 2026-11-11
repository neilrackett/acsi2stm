/* ACSI2STM Atari hard drive emulator
 * Copyright (C) 2019-2025 by Jean-Matthieu Coulon
 * Copyright (C) 2026 by Neil Rackett
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with the program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "SysHook.h"

Long SysHook::stackAlloc(int bytes)
{
  // Read the stack pointer address
  pushSp();
  Long sp;
  read(sp);

  // Allocate on the stack, compensating for the 4 bytes of pushSp
  shiftStack(4 - bytes);

  // Return
  return ToLong(sp - bytes);
}

void SysHook::sendAt(uint32_t address, const uint8_t *bytes, int count)
{
  if(count <= 0)
    return;

#if ! ACSI_PIO
  if(count < 16 || !isDma(address + count - 1)) {
    // Indirect copy: upload a byte count and the data on the ST stack, then
    // let the ST copy them. Big pieces for big copies, because programs in
    // TT-RAM read whole files this way. Small ones keep the stack use low.
    const int pieceSize = count > 30 ? 256 : 32;

    shiftStack(-pieceSize);

    while(count > 0) {
      int c = count > pieceSize - 2 ? pieceSize - 2 : count;
      Word dCount = ToWord(c - 1);
      shiftStack(0);
      send(dCount);
      sendDma(bytes, c);
      if((c + 2) & 0xf) {
        // The ST only stores DMA data by blocks of 16 bytes
        uint8_t padding[0xf];
        sendDma(padding, 16 - ((c + 2) & 0xf));
      }
      copyFromStack(address);

      address += c;
      bytes += c;
      count -= c;
    }

    shiftStack(pieceSize);
    return;
  }

  if(address & 1) {
    // Unaligned access: write the first byte indirectly
    sendAt(address, bytes, 1);
    ++address;
    ++bytes;
    --count;
  }

  while(count >= 16) {
    int blockSize = count & 0x1fff0;
    if(blockSize > (int)maxDmaFill)
      blockSize = maxDmaFill;

    setDmaRead(address);
    sendDma(bytes, blockSize);

    address += blockSize;
    bytes += blockSize;
    count -= blockSize;
  }

  if(count > 0)
    sendAt(address, bytes, count);
#else
  setDmaRead(address);
  sendDma(bytes, count);
#endif
}

void SysHook::readAt(uint8_t *bytes, uint32_t source, int count)
{
  if(count <= 0)
    return;

#if ! ACSI_PIO
  if(!isDma(source + count - 1)) {
    // Read from outside DMA RAM: use slow indirect copy
    readAtIndirect(bytes, source, count);
    return;
  }

  if(source & 1) {
    // Unaligned access: read first byte in indirect mode
    *bytes = readByteAt(source);
    ++bytes;
    ++source;
    --count;
  }

  if(count > 0) {
    setDmaWrite(source);
    readDma(bytes, count);
  }
#else
  setDmaWrite(source);
  readDma(bytes, count);
#endif
}

uint8_t SysHook::readByteAt(ToLong address)
{
  readByteToStack(address);
  uint8_t data;
  readDma((uint8_t *)&data, sizeof(data));
  shiftStack(2);
  return data;
}

Word SysHook::readWordAt(ToLong address)
{
  readWordToStack(address);
  Word data;
  readDma((uint8_t *)&data, sizeof(data));
  shiftStack(2);
  return data;
}

Long SysHook::readLongAt(ToLong address)
{
  readLongToStack(address);
  Long data;
  readDma((uint8_t *)&data, sizeof(data));
  shiftStack(4);
  return data;
}

void SysHook::readStringAt(char *bytes, ToLong address, int count)
{
  if(!count)
    return;

  if(!isDma(address))
    return readStringAtIndirect(bytes, address, count);

  if(address.bytes[3] & 1) {
    // Unaligned access
    *bytes = readByteAt(address);
    if(!*bytes)
      return;

    --count;
    if(!count)
      return;

    ++address;
    ++bytes;
  }
  setDmaWrite(address);
  readDmaString(bytes, count);
}

void SysHook::clearAt(uint32_t bytes, uint32_t address) {
  uint8_t blank[32] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};

#if ! ACSI_PIO
  if(!isDma(address + bytes - 1)) {
    // Out of DMA reach (TT-RAM, Alt-RAM): the ST copies zeros from its
    // stack. A whole TPA can be megabytes, so copy big pieces and push the
    // byte count only when it changes: one hook command per piece.
    static const uint32_t pieceSize = 128;

    // Upload some blank bytes on the stack
    shiftStack(-(int)pieceSize);
    for(uint32_t i = 0; i < pieceSize; i += sizeof(blank))
      sendDma(blank, sizeof(blank));

    int pushed = 0;
    while(bytes > 0) {
      int c = bytes > pieceSize ? pieceSize : bytes;

      if(c != pushed) {
        if(pushed)
          shiftStack(2);
        push(ToWord(c - 1));
        pushed = c;
      }
      copyFromStack(address);

      address += c;
      bytes -= c;
    }

    // Free data from stack
    shiftStack((int)pieceSize + (pushed ? 2 : 0));

    return;
  }

  if(address & 1) {
    sendAt(address, blank, 1);
    ++address;
    --bytes;
  }

  // The ST side arms the DMA sector count at 255 for each setDmaRead, and
  // the DMA chip stops writing to memory once that runs out while still
  // taking the bytes, so a single fill reaches 255 * 512 bytes at most.
  // A program's BSS can be bigger: one of 158K kept its last 30K from
  // the previous program, and that program crashed on its second run.
  // Fill in pieces, re-arming the DMA for each.
  while(bytes >= 16) {
    uint32_t chunk = bytes & 0xfffffff0;
    if(chunk > maxDmaFill)
      chunk = maxDmaFill;
    setDmaRead(address);
    DmaPort::fillDma(0, chunk);
    cacheDirty = true;
    address += chunk;
    bytes -= chunk;
  }

  if(bytes)
    sendAt(address, blank, bytes);
#else
  setDmaRead(address);
  sendCommandNoWait(0x99, bytes);
  DmaPort::repeatIrqFast(0, bytes);
#endif
}

void SysHook::readDma(uint8_t *bytes, int count)
{
  if(!count)
    return;
#if ACSI_PIO
  sendCommandNoWait(0x98, count);
  DmaPort::readIrqFast(bytes, count);
#else
  DmaPort::readDma(bytes, count);
#endif
}

void SysHook::readDmaString(char *bytes, int count)
{
  if(!count)
    return;
#if ACSI_PIO
  for(int i = 0; i < count; ++i) {
    sendCommandNoWait(0x98, 1);
    DmaPort::readIrqFast((uint8_t *)&bytes[i], 1);
    if(!bytes[i])
      return;
  }
#else
  DmaPort::readDmaString(bytes, count);
#endif
}

void SysHook::sendDma(const uint8_t *bytes, int count)
{
  if(!count)
    return;
#if ACSI_PIO
  sendCommandNoWait(0x99, count);
  DmaPort::sendIrqFast(bytes, count);
#else
  DmaPort::sendDma(bytes, count);
  cacheDirty = true;
#endif
}

uint8_t SysHook::readByte()
{
  uint8_t data;
  readDma((uint8_t *)&data, sizeof(data));
  return data;
}

Word SysHook::readWord()
{
  Word data;
  readDma((uint8_t *)&data, sizeof(data));
  return data;
}

Long SysHook::readLong()
{
  Long data;
  readDma((uint8_t *)&data, sizeof(data));
  return data;
}

void SysHook::readAtIndirect(uint8_t *bytes, ToLong source, int count) {
  if(count <= 14) {
    readAtIndirectShort(bytes, source, count);
    return;
  }

  // Make room for a 32 bytes buffer on the ST stack
  shiftStack(-32);
  while(count) {
    int l = count > 32 ? 32 : count;

    // Write byte count on the stack
    push(ToWord(l - 1));

    // Do the copy on the ST side
    copyToStack(source);

    // Fetch data
    readDma(bytes, l);

    // Pop byte count
    shiftStack(2);

    count -= l;
    bytes += l;
    source += l;
  }
  shiftStack(32);
}

void SysHook::readAtIndirectShort(uint8_t *bytes, ToLong source, int count) {
  shiftStack(-16);

  ToLong cmd[4] = {0, 0, 0, 0};
  cmd[0].bytes[1] = count - 1; // Adjust for dbra
  send(cmd);

  // Do the actual read on the ST
  copyToStack(source);

  // Fetch result
  readDma(bytes, count);

  // Free stack buffer
  shiftStack(16);
}

void SysHook::readStringAtIndirect(char *bytes, ToLong source, int count) {
  // Make room for a 32 bytes buffer on the ST stack, plus a byte count word
  shiftStack(-32);
  while(count) {
    int l = count > 32 ? 32 : count;

    // Write byte count on the stack
    push(ToWord(l - 1));

    // Do the copy on the ST side
    copyToStack(source);

    // Fetch data in a temporary buffer and do string copy from there
    {
      uint8_t lbuf[32];
      readDma(lbuf, l);
      for(int i = 0; i < l; ++i) {
        bytes[i] = (char)lbuf[i];
        if(!lbuf[i]) {
          shiftStack(2);
          goto end_of_string;
        }
      }
    }

    shiftStack(2);

    count -= l;
    bytes += l;
    source += l;
  }
end_of_string:
  shiftStack(32);
}

// Low level hook commands implementation

void SysHook::rte(int8_t value) {
#if ! ACSI_PIO
  restoreStack();
#endif
  if(value <= (int8_t)0x9a)
    rte(ToLong(value));
  dbgHex("rte(", (uint32_t)(uint8_t)value, ") ");
  DmaPort::sendIrq(value);
}

void SysHook::forward() {
#if ! ACSI_PIO
  restoreStack();
#endif
  dbg("forward ");
  DmaPort::sendIrq(0x9a);
}

void SysHook::trap1() {
  sendCommand(0x96, 0);
}

void SysHook::pushSp() {
  sendCommand(0x94, 0);
}

void SysHook::push(ToWord value) {
  sendCommand(0x92, ToLong(value));
}

void SysHook::shiftStack(ToLong offset) {
  sendCommand(0x91, offset);
}

void SysHook::readByteToStack(ToLong address) {
  sendCommand(0x8e, address);
}

void SysHook::readWordToStack(ToLong address) {
  sendCommand(0x8c, address);
}

void SysHook::readLongToStack(ToLong address) {
  sendCommand(0x8a, address);
}

void SysHook::pexec4ThenRte(ToLong pd) {
#if ! ACSI_PIO
  restoreStack();
#endif
  sendCommandNoWait(0x88, pd);
}

void SysHook::pexec6ThenRte(ToLong pd) {
#if ! ACSI_PIO
  restoreStack();
#endif
  sendCommandNoWait(0x86, pd);
}

void SysHook::setDmaRead(ToLong address)
{
  sendCommand(0x85, address);
}

void SysHook::setDmaWrite(ToLong address)
{
  sendCommand(0x84, address);
}

void SysHook::copyFromStack(ToLong address)
{
  sendCommand(0x83, address);
}

void SysHook::copyToStack(ToLong address)
{
  sendCommand(0x82, address);
}

void SysHook::rte(ToLong value) {
#if ! ACSI_PIO
  restoreStack();
#endif
  dbgHex("rte(", (uint32_t)value, ") ");
  sendCommandNoWait(0x80, value);
}

void SysHook::waitCommand() {
  DmaPort::waitCs();
  verboseHex("[{]");
  DmaPort::armCs();
}

void SysHook::sendCommand(int command, ToLong param)
{
  sendCommandNoWait(command, param);
  waitCommand();
}

void SysHook::sendCommandNoWait(int command, ToLong param)
{
#if ! ACSI_PIO
  // Flush before commands that make the ST read memory. Not needed for
  // $84/$85 (set DMA), $90/$91 (shift stack), $92 (push), $94 (push sp) and
  // $98 (the flush itself): one bit per command pair, starting at $80.
  if(!((0x1704 >> ((command - 0x80) >> 1)) & 1))
    syncCache();
#endif
  uint8_t bytes[5];
  bytes[0] = command;
  bytes[1] = param.bytes[0];
  bytes[2] = param.bytes[1];
  bytes[3] = param.bytes[2];
  bytes[4] = param.bytes[3];
#if ACSI_PIO
  DmaPort::sendIrqFast(bytes, 5);
#else
  DmaPort::sendIrqToggle(bytes, 5);
#endif
}

#if ! ACSI_PIO
void SysHook::syncCache() {
  // The 68030 caches don't see DMA writes to ST RAM. Before the ST reads
  // anything DMA wrote (stack data, buffers, loaded code), clear them.
  if(cacheFlush && cacheDirty) {
    cacheDirty = false;
    sendCommand(0x98, 0);
  }
}

void SysHook::restoreStack() {
  // Flush first: the flush command sets DMA at the last address used, which
  // must not be the caller's stack since DMA can't reach it.
  syncCache();
  if(callerSp) {
    // All that was pushed has been popped: sp is at the private stack top
    uint32_t offset = callerSp - privateSp;
    callerSp = 0;
    shiftStack(offset);
  }
}

bool SysHook::cacheFlush = false;
bool SysHook::cacheDirty = false;
uint32_t SysHook::callerSp = 0;
uint32_t SysHook::privateSp = 0;
#endif

uint32_t SysHook::dmatop = 0x40000; // Default to 256k (minimum ST-RAM)

// vim: ts=2 sw=2 sts=2 et

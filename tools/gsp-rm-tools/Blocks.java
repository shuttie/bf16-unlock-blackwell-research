import ghidra.app.script.GhidraScript;
import ghidra.program.model.mem.*;
import ghidra.program.model.address.*;
public class Blocks extends GhidraScript {
    public void run() throws Exception {
        for (MemoryBlock b : currentProgram.getMemory().getBlocks())
            println("block " + b.getName() + " " + b.getStart() + " - " + b.getEnd() + " size=" + Long.toHexString(b.getSize()));
        long[] addrs = {0x204f1168L, 0x1ef76e0L, 0x204e7bb0L, 0x42f5468L};
        for (long a : addrs) {
            Address ad = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(a);
            try {
                byte[] buf = new byte[96];
                currentProgram.getMemory().getBytes(ad, buf);
                StringBuilder sb = new StringBuilder();
                for (byte x : buf) { int c = x & 0xff; sb.append(c >= 32 && c < 127 ? (char)c : '.'); }
                println("bytes " + ad + " : " + sb);
            } catch (Exception e) { println("bytes " + ad + " : <unmapped> " + e.getMessage()); }
        }
    }
}

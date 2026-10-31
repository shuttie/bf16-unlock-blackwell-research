// For each PC: print containing function (if any) and the previous N instructions.
// Args: 0 = comma-separated hex PCs, 1 = number of prev instructions (default 20)
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;

public class PrevInsns extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] pcs = getScriptArgs()[0].split(",");
        int n = getScriptArgs().length > 1 ? Integer.parseInt(getScriptArgs()[1]) : 20;
        FunctionManager fm = currentProgram.getFunctionManager();
        for (String s : pcs) {
            Address pc = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim());
            Function f = fm.getFunctionContaining(pc);
            println("### PC " + pc + " func=" + (f == null ? "<none>" :
                    (f.getEntryPoint() + " " + f.getName())));
            java.util.ArrayList<Instruction> list = new java.util.ArrayList<>();
            Instruction insn = currentProgram.getListing().getInstructionBefore(pc);
            int guard = 0;
            while (insn != null && list.size() < n && guard < n * 4) {
                list.add(insn);
                insn = currentProgram.getListing().getInstructionBefore(insn.getAddress());
                guard++;
            }
            for (int i = list.size() - 1; i >= 0; i--) {
                Instruction it = list.get(i);
                println("    " + it.getAddress() + ": " + it.toString());
            }
        }
    }
}

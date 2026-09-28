module top;
  import "DPI-C" function int dpi_add(input int a, input int b);
  initial begin
    if (dpi_add(40, 2) == 42) $display("DPI OK");
    else $display("DPI FAIL: %0d", dpi_add(40, 2));
    $finish;
  end
endmodule

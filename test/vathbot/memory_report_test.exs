defmodule Vathbot.MemoryReportTest do
  use ExUnit.Case, async: true

  test "report/0 includes key sections" do
    report = Vathbot.MemoryReport.report()

    assert report =~ "vathbot memory report"
    assert report =~ "BEAM memory"
    assert report =~ "total"
    assert report =~ "processes"
    assert report =~ "System"
    assert report =~ "Vathbot runtime"
  end
end

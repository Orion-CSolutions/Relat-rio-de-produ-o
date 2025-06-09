# Versão sem tkinter para ambientes sem suporte a GUI
try:
    import matplotlib.pyplot as plt
    import pandas as pd
    matplotlib_disponivel = True
except ImportError:
    matplotlib_disponivel = False

def abrir_graficos(wb):
    if not matplotlib_disponivel:
        print("Erro: matplotlib não está disponível no ambiente atual.")
        return

    try:
        dados = []
        for planilha in ["IMPRESSORA", "SOS's", "APLA-2R"]:
            if planilha in wb.sheetnames:
                ws = wb[planilha]
                for row in ws.iter_rows(min_row=2, values_only=True):
                    if row and all(row):
                        dados.append({
                            "Setor": planilha,
                            "Quantidade": row[6],
                            "Refugo": row[8],
                            "Tempo Acerto": row[11] if len(row) > 11 else "00:00:00",
                            "Tempo Produção": row[12] if len(row) > 12 else "00:00:00"
                        })

        df = pd.DataFrame(dados)
        df["Quantidade"] = pd.to_numeric(df["Quantidade"], errors="coerce")
        df["Refugo"] = pd.to_numeric(df["Refugo"], errors="coerce")

        # Aplicar filtros mais específicos ao invés de descartar todos os NaNs
        df = df[df["Quantidade"].notna() & df["Refugo"].notna() & (df["Quantidade"] > 0)]

        df["%Refugo"] = (df["Refugo"] / df["Quantidade"]) * 100
        df_grouped = df.groupby("Setor").agg({
            "Quantidade": "sum",
            "Refugo": "sum",
            "%Refugo": "mean"
        })

        df_grouped.plot(kind="bar", subplots=True, layout=(2,2), figsize=(10,6), sharex=True, title="Análise de Produção por Setor")
        plt.tight_layout()
        plt.show()

    except Exception as e:
        print("Erro ao gerar gráficos:", str(e))

# Exemplo de uso:
# from openpyxl import load_workbook
# wb = load_workbook("RELATORIO_PRODUCAO_SAIDA.xlsx")
# abrir_graficos(wb)


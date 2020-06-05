import streamlit as st
import numpy as np
import pandas as pd
from process_data import process_data
import matplotlib.image as mpimg
import os

# Instantiating our Streamlit dashboard
st.title('Robot Dance')
st.header('Simulador COVID-19')

# File upload interface
st.write("Faça o upload dos arquivos para realizar a simulação.")

day_14 = st.file_uploader("14DayWindow", type="csv")
reduced_mobility = st.file_uploader("reduced_mobility", type="csv")
# file3 = st.file_uploader("file3", type="csv")
# file4 = st.file_uploader("file4", type="csv")


if (day_14 is not None):
    # Simulation running
    if (st.button('Rodar simulação!')):
        with st.spinner('Processando dados'):
            process_data(day_14, reduced_mobility)
        st.success("Concluído")

        my_bar = st.progress(0)

        imgs = [i for i in os.listdir() if (".png" in i)]
        aux = []
        for idx, path in enumerate(imgs):
            aux.append(mpimg.imread(path))
            my_bar.progress((idx + 1)/len(imgs))

        st.image(aux,
                 use_column_width=True)

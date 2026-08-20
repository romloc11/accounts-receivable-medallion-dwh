USE ANALISIS_DATOS;
GO

SELECT * FROM gold.fact_aplicacion_pagos
WHERE cliente_id = '10000914' AND documento_factura = '7404563558';
GO

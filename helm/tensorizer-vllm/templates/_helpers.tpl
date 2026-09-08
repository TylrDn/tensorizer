{{/*
Selector labels. These are the labels the Deployment matches on, the Service
selects, and the NetworkPolicy targets, so they are defined once here. `app` is
kept for backwards compatibility with releases made before this chart grew a
helpers file.
*/}}
{{- define "tensorizer-vllm.selectorLabels" -}}
app: {{ .Release.Name }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Full label set, for object metadata rather than selectors.
*/}}
{{- define "tensorizer-vllm.labels" -}}
{{ include "tensorizer-vllm.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Name of the ServiceAccount the Pod runs under.
*/}}
{{- define "tensorizer-vllm.serviceAccountName" -}}
{{- default .Release.Name .Values.serviceAccount.name }}
{{- end }}
